#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use YAML::Any;
use LIMS2::Util::YAMLIterator;

my $it = iyaml( shift @ARGV );

while ( my $plate = $it->next ) {
    while ( my ( $well_name, $well_data ) = each %{ $plate->{wells} } ) {
        if ( $well_data and keys %{$well_data} and not $well_data->{design_id} ) {
            warn "$plate->{plate_name} / $well_name missing design_id\n";
        }
    }    
}
