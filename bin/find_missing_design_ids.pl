#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use LIMS2::Model;
use LIMS2::Util::YAMLIterator;

my $model = LIMS2::Model->new( user => 'tasks' );

my %is_existing_design = map { $_->design_id => 1 } $model->schema->resultset('Design')->all;

my $it = iyaml( shift @ARGV );

while ( my $plate = $it->next ) {
    while ( my ( $well_name, $well_data ) = each %{ $plate->{wells} } ) {
        if ( $well_data and keys %{$well_data} > 0 and not $well_data->{design_id} ) {
            warn "$plate->{plate_name} / $well_name missing design_id\n";
            next;
        }
        unless ( $well_data->{design_id} ) {
            warn "$plate->{plate_name}/$well_name missing design_id\n";
            next;
        }        
        unless ( $is_existing_design{ $well_data->{design_id} } ) {
            warn "Missing design: $well_data->{design_id}\n";
        }        
    }    
}
