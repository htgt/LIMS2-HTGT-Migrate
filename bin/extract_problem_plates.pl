#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use YAML::Any;

my %plates;

for my $p ( YAML::Any::LoadFile( shift @ARGV ) ) {
    $plates{ $p->{plate_name} } = $p;
}

my %wanted;

for my $p ( @ARGV ) {
    die "Plate $p not found"
        unless exists $plates{$p};
    $wanted{$p}++;
    for my $w ( values %{ $plates{$p}{wells} } ) {
        for my $pw ( @{ $w->{parent_wells} } ) {
            my $pp = $pw->{plate_name};
            if ( $plates{$pp} ) {                
                $wanted{$pp}++;
            }
            else {
                warn "Parent plate $pp not in input file\n";
            }
        }
    }
}

for my $p ( sort { $a->{created_at} cmp $b->{created_at} } @plates{ keys %wanted } ) {
    print YAML::Any::Dump($p);
}

