#!/usr/bin/perl

# Script for simple and fast photo deflickering using imagemagick library
# Copyright Vangelis Tasoulas (cyberang3l@gmail.com)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Needed packages
use strict;
use Getopt::Std;
use strict "vars";
use feature "say";
use Image::Magick;
use Data::Dumper;
use File::Type;
use Term::ProgressBar;
use Image::ExifTool qw(:Public);
use Time::HiRes qw(gettimeofday tv_interval);
use Parallel::ForkManager;
use File::Path;

#use File::Spec;

my $startTime = [gettimeofday];

# Global variables
my $VERBOSE       = 0;
my $DEBUG         = 0;
my $rollingWindow = 15;
my $passes        = 1;
my $processes     = 2;
my $input         = '.';
my $output        = 'Deflickered';
#####################
# handle flags and arguments
# h is "help" (no arguments)
# v is "verbose" (no arguments)
# d is "debug" (no arguments)
# w is "rolling window size" (single numeric argument)
# p is "passes" (single numeric argument)
# t is "threads" (single numeric argument)
# i is "input" (path to input dir with images or file with list of images to process ... default:'.')
# o is "output" (output directory where to put processed files ... default: './Deflickered')
my $opt_string = 'hvdw:p:t:i:o:';
getopts( "$opt_string", \my %opt ) or usage() and exit 1;

# print help message if -h is invoked
if ( $opt{'h'} ) {
	usage();
	exit 0;
}

$VERBOSE       = 1         if $opt{'v'};
$DEBUG         = 1         if $opt{'d'};
$rollingWindow = $opt{'w'} if defined( $opt{'w'} );
$passes        = $opt{'p'} if defined( $opt{'p'} );
$processes     = $opt{'t'} if defined( $opt{'t'} );
$input         = $opt{'i'} if defined( $opt{'i'} );
$input =~ s|/$||; # remove trailing slash
$output	= $opt{'o'} if defined( $opt{'o'} );
$output =~ s|/$||; # remove trailing slash

#This integer test fails on "+n", but that isn't serious here.
die "The rolling average window for luminance smoothing should be a positive number greater or equal to 2"
  if !( $rollingWindow eq int($rollingWindow) && $rollingWindow > 1 );
die "The number of passes should be a positive number greater or equal to 1"  if !( $passes eq int($passes)       && $passes > 0 );
die "The number of threads should be a positive number greater or equal to 1" if !( $processes eq int($processes) && $processes > 0 );

# load image files
my @files = findFilesToProcess($input);
my $count = scalar @files;

if ( $count < 2 ) { die "Cannot process less than two files.\n" }

say "Found $count image files to be processed.";
say "\n------------ CALCULATING ORIGINAL IMAGE LUMINANCE ------------------------------\n";

# Determine luminance of each file and add to an array
# format of each value in $luminance array: {id=>array_index, filename=>name, original=>original_luminance, value=>modified_luminance}
my $luminance = computeLuminance(@files);

for ( my $pass = 1 ; $pass <= $passes ; $pass++ ) {
	say "\n\n------------ LUMINANCE SMOOTHING PASS $pass/$passes --------------------------------------\n";
	calculateNewLuminance($luminance);
}

say "\n\n------------ CHANGING IMAGE BRIGHTNESS WITH THE CALCULATED VALUES --------------\n";
modifyLuminance($luminance);

say "\n\nJob completed in " . sprintf( "%1.0f seconds.", tv_interval($startTime) );
say "$count files have been processed.";
exit 0;

#####################
# Helper routines

# create sorted list of all image files in given directory
sub findFilesToProcess() {
	my ($input) = @_;
	my $type;
	# load a raw list of files from direcotry or from list file
	my @files;
	if ( -d $input ) {
		opendir( DIR, $input ) or die "Cannot open dir $input\n";
		while ( my $file = readdir(DIR) ) {
			push( @files, $file );
		}
		closedir(DIR);
		@files = sort(@files);
	} else {
		open(IN, "< $input") or die "Cannot open list file $input\n";
		while (<IN>) {
			s/[\r\n]//g;
			next if m/^[ \t]*$/;
			next if m/^#/;
			push @files, $_;
		}
		close(IN);
	}

	# create a clean list of image files
	my $ft      = File::Type->new();
	my $prevfmt = "";
	my @out;
	for my $file (@files){
		my $type = $ft->mime_type($file);
		my ( $filetype, $fileformat ) = split( /\//, $type );
		next unless ( $filetype eq "image" );
		if ( $prevfmt eq "" ) { $prevfmt = $fileformat }
		elsif ( $prevfmt ne "warned" && $prevfmt ne $fileformat ) {
			say "Images of type $prevfmt and $fileformat detected! ARE YOU SURE THIS IS JUST ONE IMAGE SEQUENCE?";

			# no more warnings about this from now on
			$prevfmt = "warned";
		}
		push @out, $file;
	}

	# assume that the files are named in dictionary sequence - they will be processed as such.
	return @out;
}

sub initializeImageExifTool {

	#Define namespace and tag for luminance, to be used in the XMP files.
	%Image::ExifTool::UserDefined::luminance = (
		GROUPS    => { 0           => 'XMP', 1                              => 'XMP-luminance', 2 => 'Image' },
		NAMESPACE => { 'luminance' => 'https://github.com/cyberang3l/timelapse-deflicker' }, #Sort of semi stable reference?
		WRITABLE  => 'string',
		luminance => {}
	);

	%Image::ExifTool::UserDefined = (

		# new XMP namespaces (ie. XMP-xxx) must be added to the Main XMP table:
		'Image::ExifTool::XMP::Main' => {
			luminance => {
				SubDirectory => {
					TagTable => 'Image::ExifTool::UserDefined::luminance'
				},
			},
		}
	);
}

# Determine luminance of each image file in given array and return them all as an array of hashes
# format of each value in resulting array: {id=>array_index, filename=>name, original=>original_luminance, value=>original_luminance}
sub computeLuminance {
	initializeImageExifTool();
	my $pm = Parallel::ForkManager->new( $processes, '/tmp/' );
	my $luminance = [];

	# Parallel::ForkManager result retrieval
	# the sub is called with data returned from each child process
	$pm->run_on_finish(
		sub {
			# $data holds a list of luminance hashes with calculated values
			my ( $pid, $exit_code, $ident, $exit_signal, $core_dump, $data ) = @_;
			die "No message received from child process $pid!\n" unless defined($data);

			# put calculated values back to original positions in $luminance array
			foreach my $lum (@$data) {
				$luminance->[ $lum->{id} ] = $lum;
			}
		}
	);

	# split work into multiple queues for parallel processing
	my $queues = [];
	for ( my $i = 0 ; $i < @_ ; $i++ ) {
		my $lum = { id => $i, filename => $_[$i] };
		my $qId = $i % $processes;
		$queues->[$qId] = [] unless defined $queues->[$qId];
		push( @{ $queues->[$qId] }, $lum );
	}

	# process queues in parallel
	for ( my $qId = 0 ; $qId < @$queues ; $qId++ ) {

		# start new child for each queue
		$pm->start and next;
		my $q = $queues->[$qId];
		my $progressBar = Term::ProgressBar->new( { count => scalar @$q } ) if ( $qId == 0 );
		verbose( "this child got " . @$q . " images\n" );
		my $i = 0;
		foreach my $lum (@$q) {
			computeOriginalLuminance($lum);
			$progressBar->update( ++$i ) if ( $qId == 0 );
		}

		# finish the child and return calculated values
		$pm->finish( 0, $q );
	}
	$pm->wait_all_children;
	return $luminance;
}

# computes original luminance of given file
sub computeOriginalLuminance {
	my ($lum) = @_;

	# Create exifTool object for the image
	my $exifTool = new Image::ExifTool;
	my $exifinfo;    # variable to hold info read from xmp file if present.
	my $file    = $lum->{filename};
	my $xmpFile = $lum->{filename} . ".xmp";

	#If there's already an xmp file for this filename, read it.
	if ( -e $xmpFile ) {
		$exifinfo = $exifTool->ImageInfo($xmpFile);
		debug("Found xmp file: $xmpFile\n");
	}

	# Now, if it already has a luminance value, just use that:
	if ( length $$exifinfo{Luminance} ) {

		# Set it as the original and target value to start out with.
		$lum->{value} = $lum->{original} = $$exifinfo{Luminance};
		debug("Read luminance $$exifinfo{Luminance} from xmp file: $xmpFile\n");
	} else {
		my $image = Image::Magick->new;
		$image->Read($file);
		my @statistics = $image->Statistics();

		# Use the command "identify -verbose <some image file>" in order to see why $R, $G and $B
		# are read from the following index in the statistics array
		# This is the average R, G and B for the whole image.
		my $R = @statistics[ ( 0 * 7 ) + 3 ];
		my $G = @statistics[ ( 1 * 7 ) + 3 ];
		my $B = @statistics[ ( 2 * 7 ) + 3 ];

		# We use the following formula to get the perceived luminance.
		# Set it as the original and target value to start out with.
		$lum->{value} = $lum->{original} = 0.299 * $R + 0.587 * $G + 0.114 * $B;

		#Write luminance info to an xmp file.
		#This is the xmp for the input file, so it contains the original luminance.
		$exifTool->SetNewValue( luminance => $lum->{original} );

		#If there is already an xmp file, just update it:
		if ( -e $xmpFile ) {
			$exifTool->WriteInfo($xmpFile);
		} else {

			#Otherwise, create a new one:
			$exifTool->WriteInfo( undef, $xmpFile, 'XMP' );    # Write the XMP file
		}

	}
}

# calculates new luminance values for all images
sub calculateNewLuminance {
	my ($luminance) = @_;
	my $count = @$luminance;
	my $progressBar = Term::ProgressBar->new( { count => $count } );
	my $low_window  = int( $rollingWindow / 2 );
	my $high_window = $rollingWindow - $low_window;

	for ( my $i = 0 ; $i < $count ; $i++ ) {
		my $sample_avg_count = 0;
		my $avg_lumi         = 0;
		for ( my $j = ( $i - $low_window ) ; $j < ( $i + $high_window ) ; $j++ ) {
			if ( $j >= 0 and $j < $count ) {
				$sample_avg_count++;
				$avg_lumi += $luminance->[$j]->{value};
			}
		}
		$luminance->[$i]->{value} = $avg_lumi / $sample_avg_count;
		$progressBar->update( $i + 1 );
	}
}

# modifies luminance of all files based on calculated values
sub modifyLuminance {
	my ($luminance) = @_;

	# ensure output directory exists
	if ( !-d $output ) {
		mkpath($output) || die "Error creating directory: $!\n";
	}

	# split work into multiple queues for parallel processing
	my $queues = [];
	for ( my $i = 0 ; $i < @$luminance ; $i++ ) {
		my $lum = $luminance->[$i];
		my $qId = $i % $processes;
		$queues->[$qId] = [] unless ( defined $queues->[$qId] );
		push( @{ $queues->[$qId] }, $lum );
	}

	my $pm = Parallel::ForkManager->new( $processes, '/tmp/' );
	for ( my $qId = 0 ; $qId < @$queues ; $qId++ ) {
		$pm->start and next;
		my $q = $queues->[$qId];

		# progress bar is created only for first process (the progress of other processes will be similar)
		my $progressBar = Term::ProgressBar->new( { count => scalar @$q } ) if ( $qId == 0 );

		my $i = 0;
		foreach my $lum (@$q) {
			modifyOneFile($lum);
			$progressBar->update( ++$i ) if ( $qId == 0 );
		}
		$pm->finish( 0, $q );
	}
	$pm->wait_all_children;

}

# updates luminance of a single file and saves the result in "Deflickered" sub-direcotry
sub modifyOneFile {
	my ($lum) = @_;

	debug( "Original luminance of " . $lum->{filename} . ": " . $lum->{original} . "\n" );
	debug( " Changed luminance of " . $lum->{filename} . ": " . $lum->{value} . "\n" );

	my $brightness = ( 1 / ( $lum->{original} / $lum->{value} ) ) * 100;
	debug( "Imagemagick will set brightness of " . $lum->{filename} . " to: $brightness\n" );

	#my $gamma = 1 / ( $lum->{original} / $lum->{value} );
	#debug("Imagemagick will set gamma value of ".$lum->{filename}." to: $gamma\n");

	my $image = Image::Magick->new;
	$image->Read( $lum->{filename} );
	$image->Mogrify( 'modulate', brightness => $brightness );

	#$image->Gamma( gamma => $gamma, channel => 'All' );
	my $f = $lum->{filename};
	$f =~ s|.*/||; # take just filename without path (in case input file contained files in different directories)
	$image->Write( $output ."/". $f );
}

# prints the correct use of this script
sub usage {
	say <<EOT;
	
Usage:
 -w <N>     Rolling average window for luminance smoothing (Default 15)
 -p <N>     Number of luminance smoothing passes (Default 1)
              Sometimes 2 passes might give better results.
              Usually you would not want a number higher than 2.
 -t <N>     Number of threads to use for calculation and conversion (Default 2)
              Use the number of available CPU cores. Speed gain depends heavily
              on HDD perfomance.
 -i <PATH>  Input directory or list file (Default '.').
              Reads files from given directory in alphabetical order.
              If a file is given, the file should contain a list of image files 
              to be processed (possibly from multiple input directories).
              Each file must be on separate line and can be given with relative
              or absolute path. Lines starting with '#' are ignored. 
 -o <PATH>  Output directory for processed images (Default './Deflicker')
              In case the input file contained files from multiple different 
              directories they all end up in the same output dir (possibly 
              overwriting each other ... be careful with naming).
 -h         Print this usage
 -v         Verbose
 -d         Debug

EOT
}

sub verbose {
	print $_[0] if ($VERBOSE);
}

sub debug {
	print $_[0] if ($DEBUG);
}
