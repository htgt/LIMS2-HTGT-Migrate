#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use HTGT::DBFactory;
use Const::Fast;
use YAML::Any;

const my $ASSEMBLY => 'NCBIM37';

const my $SELECT_BACS_QUERY => <<'EOT';
select '129' as bac_library, trim(bac.remote_clone_id) as bac_name, build_info.golden_path, chromosome_dict.name as chromosome_name, bac.bac_start, bac.bac_end
from bac
join clone_lib_dict on clone_lib_dict.clone_lib_id = bac.clone_lib_id
join chromosome_dict on chromosome_dict.chr_id = bac.chr_id
join build_info on bac.build_id = build_info.build_id
where clone_lib_dict.library = '129'
union 
select 'black6', trim(bac.remote_clone_id), build_info.golden_path, chromosome_dict.name, bac.bac_start, bac.bac_end
from bac
join clone_lib_dict on clone_lib_dict.clone_lib_id = bac.clone_lib_id
join chromosome_dict on chromosome_dict.chr_id = bac.chr_id
join build_info on bac.build_id = build_info.build_id
where clone_lib_dict.library in ( 'black6', 'black6_M37' )
order by bac_library, bac_name
EOT

my $dbh = HTGT::DBFactory->dbi_connect( 'eucomm_vector', { FetchHashKeyName => 'NAME_lc' } );

my $select_bacs_sth = $dbh->prepare( $SELECT_BACS_QUERY );

$select_bacs_sth->execute;

my $r = $select_bacs_sth->fetchrow_hashref;

while ( $r ) {
    my %bac = (
        bac_library => $r->{bac_library},
        bac_name    => $r->{bac_name}
    );
    my @loci;
    while ( $r and $r->{bac_library} eq $bac{bac_library} and $r->{bac_name} eq $bac{bac_name} ) {
        if ( $r->{golden_path} eq $ASSEMBLY ) {
            push @loci, +{
                assembly   => $ASSEMBLY,
                chromosome => $r->{chromosome_name},
                bac_start  => $r->{bac_start},
                bac_end    => $r->{bac_end}
            };
        }
        $r = $select_bacs_sth->fetchrow_hashref;
    }
    if ( @loci == 1 ) {
        $bac{loci} = \@loci;
    }
    print YAML::Any::Dump( \%bac );
}
