#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use YAML::Any;
use IO::Handle;
use Path::Class;
use File::Temp;
use DateTime::Format::ISO8601;
use Getopt::Long;

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

my $dt = DateTime::Format::ISO8601->new;

my @plates = map  { $_->[1] }
             sort { $a->[0] <=> $b->[0] }
             map  { [ $dt->parse_datetime( $_->{created_at} ), $_ ] }
    YAML::Any::LoadFile( $file );

for my $plate ( @plates ) {
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

