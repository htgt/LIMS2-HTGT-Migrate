#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use HTGT::DBFactory;
use YAML::Any;
use LIMS2::HTGT::Migrate::Design qw( get_design_data );
use LIMS2::HTGT::Migrate::Utils;
use Log::Log4perl qw( :easy );
use Try::Tiny;
use Const::Fast;
use Getopt::Long;

const my @WANTED_DESIGN_STATUS => ( 'Ready to order', 'Ordered' );

my $log_level = $WARN;

GetOptions(
    'debug'   => sub { $log_level = $DEBUG },
    'verbose' => sub { $log_level = $INFO },
    'start=i' => \my $start_id,
    'end=i'   => \my $end_id,
    'users=s' => \my $users_yaml,
) or die "Usage: $0 [--start=START] [--end=END] [--users=FILENAME]\n";

Log::Log4perl->easy_init(
    {
        level  => $log_level,
        layout => '%p [design %x] %m%n'
    }
);

if ( defined $users_yaml ) {
    $LIMS2::HTGT::Migrate::Utils::USERS_YAML = $users_yaml;
}

my $schema = HTGT::DBFactory->connect( 'eucomm_vector' );

my $run_date = DateTime->now;

my $designs_rs;

if ( @ARGV ) {
    $designs_rs = $schema->resultset( 'Design' )->search( { design_id => \@ARGV } );
}
else {
    my %search = (
        'statuses.is_current'            => 1,
        'design_status_dict.description' => \@WANTED_DESIGN_STATUS
    );
    if ( defined $start_id and defined $end_id ) {
        $search{'-and'} = [
            { 'me.design_id' => { '>=', $start_id } },
            { 'me.design_id' => { '<',  $end_id   } }
        ]
    }
    elsif ( defined $start_id ) {
        $search{'me.design_id'} = { '>=', $start_id };
    }
    elsif ( defined $end_id ) {
        $search{'me.design_id'} = { '<', $end_id };
    }
    $designs_rs = $schema->resultset( 'Design' )->search(
        \%search,
        {
            join => { 'statuses' => 'design_status_dict' },
            distinct => 1
        }
    );
}

while ( my $design = $designs_rs->next ) {
    Log::Log4perl::NDC->push( $design->design_id );
    try {
        my $data = get_design_data( $design );
        print YAML::Any::Dump( $data );
    }
    catch {
        ERROR($_);
    }
    finally {        
        Log::Log4perl::NDC->pop;        
    };    
}

__END__
