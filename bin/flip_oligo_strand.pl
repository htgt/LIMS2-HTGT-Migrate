#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use HTGT::DBFactory;
use Log::Log4perl ':easy';
use Getopt::Long;
use Try::Tiny;
use Perl6::Slurp;
use Smart::Comments;
use Const::Fast;
use Bio::Seq;

const my %STRAND_MAP => (
    1 => -1,
    -1 => 1,
);

my $schema = HTGT::DBFactory->connect('eucomm_vector');

GetOptions(
    'id=i'   => \my $design_id,
    'commit' => \my $commit,
);

Log::Log4perl->easy_init( { level => $DEBUG, layout => '%p %x %m%n' } );

if ( $design_id ) {
    try{
        flip_oligo_strand( $design_id );
    }
    catch {
        DEBUG( $_ );
    };
}
else {
    my @design_ids = map{ chomp; $_ } slurp( $ARGV[0] ); 

    for my $design_id ( @design_ids ) {
        try{
            flip_oligo_strand( $design_id );
        }
        catch {
            DEBUG( $_ );
        };
    }

    INFO( 'DONE!!' );
}

sub flip_oligo_strand {
    my $design_id = shift;
    Log::Log4perl::NDC->push( $design_id );

    my $design = $schema->resultset('Design')->find( { design_id => $design_id } );
    my $chr_strand = $design->info->chr_strand;

    my $display_features = $design->validated_display_features;

    for my $df ( values %{ $display_features } ) {
        flip_display_feature_strand( $df, $STRAND_MAP{$chr_strand} );
    }

    Log::Log4perl::NDC->remove;
}

sub flip_display_feature_strand{
    my ( $df, $strand ) = @_;
    Log::Log4perl::NDC->push( $df->display_feature_type );

    $schema->txn_do(
        sub{
            INFO( 'Flipping strand from ' . $df->feature_strand . ' to ' . $strand );
            $df->update( { feature_strand => $strand } );

            if ( !$commit ) {
                INFO('Rollback');
                $schema->txn_rollback;
            }
        }
    );
    Log::Log4perl::NDC->pop;
}
