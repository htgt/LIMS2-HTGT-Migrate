#!/usr/bin/env perl

use strict;
use HTGT::DBFactory;
use LIMS2::REST::Client;
use Perl6::Slurp;
use Const::Fast;
use Smart::Comments;
use List::MoreUtils qw(uniq);
use Log::Log4perl qw( :easy );
use Try::Tiny;
use Getopt::Long;

my $lims2;

const my @OLIGO_NAMES => qw( G5 U5 U3 D5 D3 G3 );
const my $ASSEMBLY => 'GRCm38';
my $schema = HTGT::DBFactory->connect('eucomm_vector');

{
    my %log4perl = (
        level  => $WARN,
        layout => '%d %p %x %m%n'
    );

    GetOptions(
        'verbose'     => sub { $log4perl{level} = $INFO },
    );

    Log::Log4perl->easy_init( \%log4perl );
    $lims2 = LIMS2::REST::Client->new_with_config();

    my @designs = split( "\n", slurp($ARGV[0]) );

    for my $design_id (@designs){
      migrate_design_oligo_loci( $design_id );
    }
}


sub migrate_design_oligo_loci {
    my $design_id = shift;
    Log::Log4perl::NDC->pop;
    Log::Log4perl::NDC->push( $design_id );

    my $design = $schema->resultset('Design')->find({ 'design_id'=> $design_id});
    my $oligos = oligos_for($design, type_for($design));

    INFO( "Create design oligo loci for $design_id on assembly $ASSEMBLY" );

    my $lims2_design = try {
        retrieve_lims2_design( $design_id )
    };
    die("design does not exist in lims2: " . $design_id) unless $lims2_design;

    my %lims_oligos_details = map {$_->{type} => $_->{locus}{assembly}} @{$lims2_design->{oligos}};
    for my $oligo (@{$oligos}){
        if (! exists $lims_oligos_details{$oligo->{oligo_type}} or $lims_oligos_details{$oligo->{oligo_type}} ne $oligo->{assembly}){
            ### CREATED: create oligo for design: $oligo->{design_id} . ' type ' . $oligo->{oligo_type}
            $lims2->POST( 'design_oligo_locus', $oligo );
        }
        else {
            ### ALREADY EXISTS: did not create oligo for design: $oligo->{design_id} . ' type ' . $oligo->{oligo_type}
        }
    }
}

sub retrieve_lims2_design {
    my $design_id = shift;

    my $design = try {
        $lims2->GET( 'design', { id => $design_id } );
    }
    catch {
        $_->throw() unless $_->not_found;
        undef;
    };

    return $design;
}

sub oligos_for {
    my ( $design, $design_type ) = @_;

    my @oligoloci;

    my $features = $design->validated_display_features;

    for my $oligo_name ( @OLIGO_NAMES ) {
        my $oligo = $features->{$oligo_name} or next;
        push @oligoloci, {
            design_id  => $design->design_id,
            oligo_type => $oligo_name,
            assembly   => $ASSEMBLY,
            chr_name   => $oligo->chromosome->name,
            chr_start  => $oligo->feature_start,
            chr_end    => $oligo->feature_end,
            chr_strand => $oligo->feature_strand
        };
    }
    sanity_check_oligos( $design_type, \@oligoloci );

    return \@oligoloci;
}

sub sanity_check_oligos {
    my ( $design_type, $oligos ) = @_;
    my %oligos_hash = map {$_->{oligo_type} => $_} @{$oligos};

    die "Design has no validated oligos with $ASSEMBLY locus\n"
        unless @{$oligos} > 1;

    my @chromosomes = uniq map { $_->{chr_name} } @{$oligos} ;
    die "Oligos have inconsistent chromosome\n" unless @chromosomes == 1;

    my @strands = uniq map { $_->{chr_strand} } @{$oligos};
    die "Oligos have inconsistent strand\n" unless @strands == 1;

    my @oligo_names = $strands[0] eq 1 ? @OLIGO_NAMES : reverse @OLIGO_NAMES;

    if ( $design_type eq 'insertion' or $design_type eq 'deletion' ) {
        @oligo_names = grep { $_ ne 'U3' and $_ ne 'D5' } @oligo_names;
    }

    for my $o ( @oligo_names ) {
        die "Expected oligo $o has no locus\n"
            unless exists $oligos_hash{$o};
        die "Oligo $o has end before start\n"
            unless $oligos_hash{$o}->{chr_end} > $oligos_hash{$o}->{chr_start};
    }

    for my $ix ( 0 .. (@oligo_names - 2) ) {
        my $o1 = $oligo_names[$ix];
        my $o2 = $oligo_names[$ix+1];
        die "Oligos $o1 and $o2 in unexpected order\n"
            unless $oligos_hash{$o1}->{chr_end} <= $oligos_hash{$o2}->{chr_start};
    }
}

sub type_for {
    my $design = shift;

    my $intron_replacement =
        $design->search_related_rs( 'design_user_comments',
                                  {
                                      'category.category_name' => 'Intron replacement'
                              },
                              {
                                  join => 'category'
                              }
                          )->count;

    if ( $intron_replacement > 0 ) {
        return 'intron-replacement';
    }

    if ( $design->is_artificial_intron ) {
        return 'artificial-intron';
    }

    my $dt = $design->design_type;

    if ( !defined($dt) || $dt =~ /^KO/ ) {
        return 'conditional';
    }

    if ( $dt =~ /^Ins/ ) {
        return 'insertion';
    }

    if ( $dt =~ /^Del/ ) {
        return 'deletion';
    }

    die "Unrecognized design type '$dt'\n";
}

