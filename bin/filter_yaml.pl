#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use YAML::Any;
use LIMS2::Util::YAMLIterator;
use IO::Handle;
use Path::Class;
use File::Temp;
use Getopt::Long;
use Data::Dump 'pp';

GetOptions(
    'i:s' => \my $inplace
) and @ARGV == 1 or die "Usage: $0 FILENAME.YAML\n";

my $file = file( shift @ARGV );

my $ofh;
if ( defined $inplace ) {
    $ofh = File::Temp->new( DIR => $file->dir )
        or die "create tmp file: $!";
}
else {
    $ofh = IO::Handle->new->fdopen( fileno(STDOUT), 'w' )
        or die "fdopen STDOUT: $!";
}

my %seen;

my $it = iyaml( $file->openr );

while ( my $plate = $it->next ) {
    while ( my ( $well_name, $well ) = each %{ $plate->{wells} } ) {
        if ( $well->{accepted} and not $well->{assay_complete} ) {
            $well->{assay_complete} = $well->{accepted}->{created_at};
        }
    }
    $ofh->print( Dump( $plate ) );
}

$ofh->close;

if ( defined $inplace and length $inplace ) {
    rename( $file, $file . $inplace )
        or die "backup $file: $!";
}

if ( defined $inplace ) {
    rename( $ofh->filename, $file )
        or die "rename tmp file: $!";    
}

