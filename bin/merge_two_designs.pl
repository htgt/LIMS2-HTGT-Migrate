#! /usr/bin/env perl
use strict;
use warnings FATAL => 'all';

=head1 NAME

merge_two_designs

=head1 DESCRIPTION

Barry has taken a design in htgt and manually shortened the arms in a new design.
We need to take the initial design and swap out its G oligos with the G oligos
from the new design with the shorter arms.

Input:
CSV file with 2 columns, first column has the base design id.
Second column has the shortened arm design id.

Output:
Dump a yaml file to STDOUT with new designs data.

=cut

use LIMS2::HTGT::Migrate::Design qw( get_design_data );
use YAML::Any;
use HTGT::DBFactory;
use DateTime;
use Perl6::Slurp;
use Log::Log4perl qw( :easy );

my $schema = HTGT::DBFactory->connect( 'eucomm_vector' );
my $current_time = DateTime->now->ymd;
Log::Log4perl->easy_init( { level => $INFO } );

my @design_merges = map{ chomp; $_ } slurp( $ARGV[0] );

for my $designs ( @design_merges ) {
    my ( $base_design_id, $short_arm_design_id ) = split( ',', $designs );
    merge_designs( $base_design_id, $short_arm_design_id );
}

sub merge_designs{
    my ( $base_design_id, $short_arm_design_id ) = @_;
    INFO( "Merging base design $base_design_id with short arm design $short_arm_design_id" );

    my $base_design = $schema->resultset('Design')->find( { design_id => $base_design_id } );
    my $short_arm_design = $schema->resultset('Design')->find( { design_id => $short_arm_design_id } );

    my $base_design_data = get_design_data( $base_design );
    my $short_arm_design_data = get_design_data( $short_arm_design );

    # remove G oligos from base design
    my @oligos = grep{ $_->{type} !~ /G[5|3]/ } @{ $base_design_data->{oligos} };

    # grab G oligos from short arm design
    my @g_oligos = grep{ $_->{type} =~ /G[5|3]/ } @{ $short_arm_design_data->{oligos} };

    die ( "We don't have 2 G oligos" ) if scalar( @g_oligos ) != 2;

    # merge oligos
    push @oligos, @g_oligos;

    $base_design_data->{oligos} = \@oligos;

    # Remove data we should not replicate
    delete $base_design_data->{id};
    delete $base_design_data->{name};
    delete $base_design_data->{comments};
    delete $base_design_data->{genotyping_primers};
    delete $base_design_data->{validated_by_annotation};

    # Add a comment about the origins of this design
    my $comment = 'Imported from HTGT - Short arm version of design: ' . $base_design->design_id
        . ' using G oligos from design: ' . $short_arm_design->design_id;
    $base_design_data->{comments} = [
        {
            category     => 'Other',
            comment_text => $comment,
            created_at   => $current_time,
            created_by   => 'sp12@sanger.ac.uk',
            is_public    => 1,
        }
    ];

    print YAML::Any::Dump( $base_design_data );
}

