#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use YAML::Any;
use LIMS2::Util::YAMLIterator;
use LIMS2::HTGT::Migrate::Utils qw( parse_oracle_date );
use HTGT::DBFactory;

my $dbh = HTGT::DBFactory->dbi_connect( 'eucomm_vector', { FetchHashKeyName => 'NAME_lc' } );

my $sth = $dbh->prepare(<<'EOT');
select plate.name as plate_name, well.well_name, well_data.data_value, well_data.edit_date, well_data.edit_user
from plate
join well on well.plate_id = plate.plate_id
join well_data on well_data.well_id = well.well_id
where plate.type in ('PC', 'PCS')
and well_data.data_type = 'distribute'
EOT

$sth->execute;

my $dist_data = $sth->fetchall_hashref( [ qw( plate_name well_name ) ] );

my $it = iyaml( shift @ARGV );

while ( my $plate = $it->next ) {
    while ( my ( $well_name, $well_data ) = each %{ $plate->{wells} } ) {
        if ( exists $well_data->{accepted} ) {
            if ( $well_data->{accepted} == 0 ) {
                delete $well_data->{accepted};
            }
            else {
                my $d = $dist_data->{ $plate->{plate_name} }{ $well_name };                
                $well_data->{accepted} = {
                    accepted   => $d->{data_value} eq 'yes' ? 1 : 0,
                    created_at => parse_oracle_date( $d->{edit_date} )->iso8601,
                    created_by => $d->{edit_user} || 'migrate_script'
                };                
            }
        }        
    }
    print Dump( $plate );    
}
