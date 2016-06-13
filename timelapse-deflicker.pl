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

#use File::Spec;

my $startTime = [gettimeofday];

# Global variables
my $VERBOSE       = 0;
my $DEBUG         = 0;
my $RollingWindow = 15;
my $Passes        = 1;
my $Processes     = 2;

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

#####################
# handle flags and arguments
# h is "help" (no arguments)
# v is "verbose" (no arguments)
# d is "debug" (no arguments)
# w is "rolling window size" (single numeric argument)
# p is "passes" (single numeric argument)
# t is "threads" (single numeric argument)
my $opt_string = 'hvdw:p:t:';
getopts( "$opt_string", \my %opt ) or usage() and exit 1;

# print help message if -h is invoked
if ( $opt{'h'} ) {
	usage();
	exit 0;
}

$VERBOSE       = 1         if $opt{'v'};
$DEBUG         = 1         if $opt{'d'};
$RollingWindow = $opt{'w'} if defined( $opt{'w'} );
$Passes        = $opt{'p'} if defined( $opt{'p'} );
$Processes     = $opt{'t'} if defined( $opt{'t'} );

#This integer test fails on "+n", but that isn't serious here.
die "The rolling average window for luminance smoothing should be a positive number greater or equal to 2"
  if !( $RollingWindow eq int($RollingWindow) && $RollingWindow > 1 );
die "The number of passes should be a positive number greater or equal to 1"  if !( $Passes eq int($Passes)       && $Passes > 0 );
die "The number of threads should be a positive number greater or equal to 1" if !( $Processes eq int($Processes) && $Processes > 0 );

# Create hash to hold luminance values.
# Format will be: TODO: Add this here
my $luminance = [];

# The working directory is the current directory.
my $data_dir = ".";
opendir( DATA_DIR, $data_dir ) || die "Cannot open $data_dir\n";

#Put list of files in the directory into an array:
my @files;
my $prevfmt = "";

# create a clean list of image files (no '.',  '..' and other garbage)
while ( my $file = readdir(DATA_DIR) ) {
	my $ft   = File::Type->new();
	my $type = $ft->mime_type($file);
	my ( $filetype, $fileformat ) = split( /\//, $type );
	next unless ( $filetype eq "image" );
	if ( $prevfmt eq "" ) { $prevfmt = $fileformat }
	elsif ( $prevfmt ne "warned" && $prevfmt ne $fileformat ) {
		say "Images of type $prevfmt and $fileformat detected! ARE YOU SURE THIS IS JUST ONE IMAGE SEQUENCE?";

		# no more warnings about this from now on
		$prevfmt = "warned";
	}
	push @files, $file;
}

#Assume that the files are named in dictionary sequence - they will be processed as such.
@files = sort @files;

#Initialize count variable to number files in hash
my $count = 0;

#Initialize a variable to hold the previous image type detected - if this changes, warn user
my $prevfmt = "";

if ( @files < 2 ) { die "Cannot process less than two files.\n" }

say "Found ".@files." image files to be processed.";
say "Original luminance of Images is being calculated";

#Determine luminance of each file and add to the hash.
luminance_det();

my $CurrentPass = 1;

while ( $CurrentPass <= $Passes ) {
	say "\n-------------- LUMINANCE SMOOTHING PASS $CurrentPass/$Passes --------------\n";
	new_luminance_calculation();
	$CurrentPass++;
}

say "\n\n-------------- CHANGING OF BRIGHTNESS WITH THE CALCULATED VALUES --------------\n";
luminance_change();

say "\n\nJob completed in " . sprintf( "%1.0f seconds.", tv_interval($startTime) );
say @$luminance." files have been processed";

#####################
# Helper routines

#Determine luminance of each image; add to hash.
sub luminance_det {
	my $pm = Parallel::ForkManager->new( $Processes, '/tmp/' );

	# data structure retrieval and handling
	$pm->run_on_finish(
		sub {
			my ( $pid, $exit_code, $ident, $exit_signal, $core_dump, $data ) = @_;

			# retrieve data structure from child
			if ( defined($data) ) {
				foreach my $lum (@$data) {
					$luminance->[ $lum->{id} ] = $lum;
				}
			} else {
				die "No message received from child process $pid!\n";
			}
		}
	);

	my $queues = [];

	for ( my $i = 0 ; $i < @files ; $i++ ) {
		my $lum = { id => $i, filename => $files[$i] };
		my $qId = $i % $Processes;
		unless ( defined $queues->[$qId] ) {
			$queues->[$qId] = [];
		}
		push( @{ $queues->[$qId] }, $lum );
	}

	my $qId = 0;
	foreach my $q (@$queues) {
		$qId++;
		$pm->start and next;
		my $progress;
		if ( $qId == 1 ) {
			$progress = Term::ProgressBar->new( { count => scalar @$q } );
		}
		verbose( "this child got " . @$q . " images\n" );
		my $i = 0;
		foreach my $lum (@$q) {
			computeOriginalLuminance($lum);
			if ( $qId == 1 ) {
				$progress->update( ++$i );
			}
		}
		$pm->finish( 0, $q );
	}
	$pm->wait_all_children;
}

sub computeOriginalLuminance {
	my ($lum) = @_;

	#Create exifTool object for the image
	my $exifTool = new Image::ExifTool;
	my $exifinfo;                 #variable to hold info read from xmp file if present.

	#If there's already an xmp file for this filename, read it.
	if ( -e $lum->{filename} . ".xmp" ) {
		$exifinfo = $exifTool->ImageInfo( $lum->{filename} . ".xmp" );
		debug( "Found xmp file: " . $lum->{filename} . ".xmp\n" );
	}

	#Now, if it already has a luminance value, just use that:
	if ( length $$exifinfo{Luminance} ) {

		# Set it as the original and target value to start out with.
		$lum->{value} = $lum->{original} = $$exifinfo{Luminance};
		debug( "Read luminance $$exifinfo{Luminance} from xmp file: " . $lum->{filename} . ".xmp\n" );
	} else {
		my $image = Image::Magick->new;
		$image->Read( $lum->{filename} );
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
		if ( -e $lum->{filename} . ".xmp" ) {
			$exifTool->WriteInfo( $lum->{filename} . ".xmp" );

			#Otherwise, create a new one:
		} else {
			$exifTool->WriteInfo( undef, $lum->{filename} . ".xmp", 'XMP' );    #Write the XMP file
		}

	}
}

sub new_luminance_calculation {
	my $count = @$luminance;
	my $progress    = Term::ProgressBar->new( { count => scalar $count} );
	my $low_window  = int( $RollingWindow / 2 );
	my $high_window = $RollingWindow - $low_window;

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

		$progress->update( $i + 1 );
	}
}

sub luminance_change {

	if ( !-d "Deflickered" ) {
		mkdir("Deflickered") || die "Error creating directory: $!\n";
	}

	my $queues = [];

	for ( my $i = 0 ; $i < @$luminance ; $i++ ) {
		my $lum = $luminance->[$i];
		my $qId = $i % $Processes;
		unless ( defined $queues->[$qId] ) {
			$queues->[$qId] = [];
		}
		push( @{ $queues->[$qId] }, $lum );
	}

	my $pm = Parallel::ForkManager->new( $Processes, '/tmp/' );
	my $qId = 0;
	my $progress;
	foreach my $q (@$queues) {
		$qId++;
		$pm->start and next;
		if ( $qId == 1 ) {
			$progress = Term::ProgressBar->new( { count => scalar @$q } );
		}
		my $i = 0;
		foreach my $lum (@$q) {
			modifyLuminance($lum);
			if ( $qId == 1 ) {
				$progress->update( ++$i );
			}
		}
		$pm->finish( 0, $q );
	}
	$pm->wait_all_children;

}

sub modifyLuminance {
	my ($lum) = @_;

	debug( "Original luminance of " . $lum->{filename} . ": " . $lum->{original} . "\n" );
	debug( " Changed luminance of " . $lum->{filename} . ": " . $lum->{value} . "\n" );

	my $brightness = ( 1 / ( $lum->{original} / $lum->{value} ) ) * 100;

	#my $gamma = 1 / ( $lum->{original} / $lum->{value} );

	debug( "Imagemagick will set brightness of " . $lum->{filename} . " to: $brightness\n" );

	#debug("Imagemagick will set gamma value of ".$lum->{filename}." to: $gamma\n");

	debug("Changing brightness of $lum->{filename} and saving to the destination directory...\n");
	my $image = Image::Magick->new;
	$image->Read( $lum->{filename} );

	$image->Mogrify( 'modulate', brightness => $brightness );

	#$image->Gamma( gamma => $gamma, channel => 'All' );
	$image->Write( "Deflickered/" . $lum->{filename} );
}

sub usage {

	# prints the correct use of this script
	say "Usage:";
	say "-w    Choose the rolling average window for luminance smoothing (Default 15)";
	say "-p    Number of luminance smoothing passes (Default 1)";
	say "       Sometimes 2 passes might give better results.";
	say "       Usually you would not want a number higher than 2.";
	say "-t    Number of threads (processes) to use for calculation and conversion";
	say "       Use number of available CPU cores. Speed gain depends heavily";
	say "       on HDD perfomance (Default 2)";
	say "-h    Usage";
	say "-v    Verbose";
	say "-d    Debug";
}

sub verbose {
	print $_[0] if ($VERBOSE);
}

sub debug {
	print $_[0] if ($DEBUG);
}
