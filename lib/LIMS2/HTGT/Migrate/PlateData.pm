package LIMS2::HTGT::Migrate::PlateData;

use Moose;
use LIMS2::HTGT::Migrate::Utils qw( htgt_plate_types
                                    lims2_plate_type
                                    format_well_name
                                    is_consistent_design_instance
                                    sponsor2pipeline
                              );
use DateTime;
use DateTime::Format::Oracle;
use Const::Fast;
use YAML::Any;
use Try::Tiny;
use namespace::autoclean;

has schema => (
    is         => 'ro',
    isa        => 'HTGTDB',
    lazy_build => 1
);

has qc_schema => (
    is         => 'ro',
    isa        => 'ConstructQC',
    lazy_build => 1
);

has limit => (
    is     => 'ro',
    isa    => 'Maybe[Int]',
);

has plate_names => (
    is => 'ro',
    isa => 'Maybe[ArrayRef]',
);

has created_after => (
    is     => 'ro',
    isa    => 'Maybe[DateTime]',
);

has run_date => (
    is      => 'ro',
    isa     => 'DateTime',
    default => sub { DateTime->now }
);

has created_date => (
    is      => 'rw',
    isa     => 'DateTime',
);

has htgt_plate_data => (
    isa     => 'HashRef',
    traits  => [ 'Hash' ],
    writer  => 'set_htgt_plate_data',
    handles => {
        get_htgt_plate_data => 'get',
        htgt_plate_data     => 'values'
    }
);

has htgt_well_data => (
    isa     => 'HashRef',
    traits  => [ 'Hash' ],
    writer  => 'set_htgt_well_data',
    handles => {
        get_htgt_well_data => 'get',
        htgt_well_data     => 'values'
    }
);

has plate_type => (
    is       => 'ro',
    isa      => 'Str',
    init_arg => undef
);

has migrate_user => (
    is       => 'ro',
    isa      => 'Str',
    default  => 'migrate_script'
);

with qw( MooseX::Log::Log4perl );

sub _build_schema {
    require HTGT::DBFactory;
    HTGT::DBFactory->connect( 'eucomm_vector' );
}

sub _build_qc_schema {
    require HTGT::DBFactory;
    HTGT::DBFactory->connect( 'vector_qc' );
}

sub init_htgt_plate_data {
    my ( $self, $plate ) = @_;
    my %plate_data = map { $self->trim( $_->data_type ) => $_ } $plate->plate_data;
    $self->set_htgt_plate_data( \%plate_data );    
}

sub init_htgt_well_data {
    my ( $self, $well ) = @_;
    my %well_data = map { $self->trim( $_->data_type ) => $_ } $well->well_data;
    $self->set_htgt_well_data( \%well_data );
}

sub get_htgt_plate_data_value {
    my ( $self, $data_type ) = @_;
    my $plate_data = $self->get_htgt_plate_data( $data_type );
    return $plate_data ? $plate_data->data_value : undef;
}

sub get_htgt_well_data_value {
    my ( $self, $data_type ) = @_;
    my $well_data = $self->get_htgt_well_data( $data_type );
    return $well_data ? $well_data->data_value : undef;
}

sub plate_resultset {
    my $self = shift;
    
    my %search = (
        'me.type' => htgt_plate_types( $self->plate_type ),
    );

    if ( $self->limit ) {
        $search{rownum} = { '<=', $self->limit };
    }

    if ( $self->created_after ) {
        $search{'me.created_date'} = { '>', $self->created_after };
        
    }    

    if ( $self->plate_names ) {
        $search{'name'} = { 'IN', $self->plate_names };
    }
    
    return $self->schema->resultset( 'Plate' )->search(
        \%search,
        {
            order_by => { -asc => 'created_date' }
        }
    );
}

sub dump_plate_data {
    my $self = shift;

    my $plate_rs = $self->plate_resultset;
        
    while ( my $plate = $plate_rs->next ) {
        Log::Log4perl::NDC->push( $plate->name );
        try {
            my $data = $self->plate_data( $plate );
            print Dump( $data );
        }
        catch {
            $self->log->error($_);
        }
        finally {        
            Log::Log4perl::NDC->pop;
        }    
    }
}

sub plate_data {
    my ( $self, $plate ) = @_;

    $self->created_date( $plate->created_date || $self->run_date );
    $self->init_htgt_plate_data( $plate );

    my %data = (
        plate_name  => $plate->name,
        plate_type  => lims2_plate_type( $plate->type ),
        plate_desc  => $plate->description || '',
        created_by  => $plate->created_user || $self->migrate_user,
        created_at  => $self->created_date->iso8601,
        comments    => $self->plate_comments( $plate ),
        wells       => $self->wells( $plate )
    );

    # Add 384-well plates to a plate group
    my $is_384 = $self->get_htgt_plate_data( 'is_384' ) || 'no';
    if ( $is_384 eq 'yes' ) {
        ( my $plate_group = $plate->name ) =~ s/_\d+$//
            or die "Failed to determine plate group for " . $plate->name;
        $data{plate_group} = $plate_group;
    }
    
    # XXX What about plate_blobs?
    
    return \%data;
}

sub plate_comments {
    my ( $self, $plate ) = @_;

    my @comments;

    for my $c ( $plate->plate_comments ) {
        my $created_at = $self->parse_oracle_date( $c->edit_date ) || $self->created_date;
        push @comments, {
            plate_comment => $c->plate_comment,
            created_by    => $c->edit_user || $self->migrate_user,
            created_at    => $created_at->iso8601
        }
    }

    return \@comments;
}

sub wells {
    my ( $self, $plate ) = @_;

    my %wells;

    for my $well ( $plate->wells ) {
        my $well_name = format_well_name( $well->well_name );
        die "Duplicate well $well_name" if $wells{$well_name};
        $wells{$well_name} = $self->well_data( $well );
    }

    return \%wells;
}

sub well_data {
    my ( $self, $well ) = @_;
    
    $self->init_htgt_well_data( $well );

    return {} unless defined $well->design_instance_id;
    
    my %data = (
        created_at   => $self->created_date->iso8601,
        comments     => $self->well_comments( $well ),
        accepted     => $self->accepted_override( $well ),
        parent_wells => $self->parent_wells( $well ),
        pipeline     => $self->pipeline_for( $well )
    );

    if ( $data{accepted} ) {
        $data{assay_complete} = $data{accepted}->{created_at};
    }    
    
    return \%data;
}

sub pipeline_for {
    my ( $self, $well ) = @_;

    my $sponsor = ( $self->get_htgt_well_data_value( 'sponsor' )
                        || $self->get_htgt_plate_data_value( 'sponsor' ) );

    return undef unless defined $sponsor;

    return sponsor2pipeline( $sponsor );    
}

sub well_comments {
    my ( $self, $well ) = @_;

    my @comments;
    for my $c ( grep { $_->data_type =~ m/comments?/i } $self->htgt_well_data ) {
        my $created_at = $self->parse_oracle_date( $c->edit_date ) || $self->created_date;        
        push @comments, {
            created_at => $created_at->iso8601,
            created_by => $c->edit_user || $self->migrate_user,
            comment    => $self->trim( $c->data_value )
        };
    }

    return \@comments;
}

sub accepted_override {
    my ( $self, $well ) = @_;

    my $dist = $self->get_htgt_well_data( 'distribute' )
        or return undef;

    return +{
        accepted   => $dist->data_value eq 'yes' ? 1 : 0,
        created_at => $self->parse_oracle_date( $dist->edit_date )->iso8601,
        created_by => $dist->edit_user || $self->migrate_user
    };        
}

sub parent_wells {
    my ( $self, $well ) = @_;

    my @parent_wells;
    
    if ( $well->parent_well_id ) {
        my $parent_well = $well->parent_well;
        if ( is_consistent_design_instance( $well, $parent_well ) ) {
            push @parent_wells, +{
                plate_name => $parent_well->plate->name,
                well_name  => $parent_well->well_name
            };
        }
        else {            
            $self->log->warn( "$well design instance mismatch" );
        }
    }

    return \@parent_wells;
}

sub get_legacy_qc_data {
    my ( $self, $well ) = @_;    

    my $qctest_well_data = $self->get_htgt_well_data( 'qctest_result_id' )
        or return;
    
    my $qctest_result_id = $qctest_well_data->data_value;
    
    my $qctest_result = $self->qc_schema->resultset( 'QctestResult' )->find(
        {
            qctest_result_id => $qctest_result_id
        }
    ) or return;

    my %valid_primers;
    
    foreach my $primer ( $qctest_result->qctestPrimers ) {
        my $seq_align_feature = $primer->seqAlignFeature
            or next;
        my $loc_status = $seq_align_feature->loc_status
            or next;
        $valid_primers{ uc( $primer->primer_name ) } = 1
            if $loc_status eq 'ok';
    }
    
    my $run_date   = $self->parse_oracle_date( $qctest_result->qctestRun->run_date )->iso8601;
    my $pass_level = $self->get_htgt_well_data_value( 'pass_level' ) || 'fail';    

    return +{
        legacy_qc_test_result => {
            qc_test_result_id => $qctest_result_id,
            pass_level        => $pass_level,
            valid_primers     => join( q{,}, sort keys %valid_primers )
        },
        assay_pending         => $run_date,
        assay_results         => [
            {
                assay      => 'sequencing_qc',
                result     => $self->sequencing_qc_pass_fail( $well ),
                created_at => $run_date,
                created_by => $qctest_well_data->edit_user || $self->migrate_user
            }
        ],
        assay_complete        => $self->parse_oracle_date( $qctest_well_data->edit_date )->iso8601
    };
}

sub get_qc_data {
    my ( $self, $well ) = @_;

    my $tr_well_data = $self->get_htgt_well_data( 'new_qc_test_result_id' )
        or return;
    
    my $qc_date     = $self->parse_oracle_date( $tr_well_data->edit_date )->iso8601;
    my $pass_level  = $self->get_htgt_well_data_value( 'pass_level' ) || 'fail';
    my $mixed_reads = $self->get_htgt_well_data_value( 'mixed_reads' ) || 'no';

    return +{
        qc_test_result => {
            qc_test_result_id => $tr_well_data->data_value,
            valid_primers     => $self->get_htgt_well_data_value( 'valid_primers' ) || '',
            pass              => $pass_level eq 'pass' ? 1 : 0,
            mixed_reads       => $mixed_reads eq 'yes' ? 1 : 0
        },
        assay_results => [
            {
                assay      => 'sequencing_qc',
                result     => $pass_level,
                created_at => $qc_date,
                created_by => $tr_well_data->edit_user || $self->migrate_user
            }
        ],
        assay_pending  => $qc_date,
        assay_complete => $qc_date
    };
}


#
# Utility functions
#

sub merge_well_data {
    my ( $self, $data, $new_data ) = @_;

    const my %IGNORE => map { $_ => 1 } qw( assay_pending assay_results assay_complete );

    for my $k ( grep { ! exists $IGNORE{$_} } keys %{$new_data} ) {
        if ( exists $data->{$k} and defined $data->{$k} ) {
            $self->log->warn( "Overriding $k: $data->{$k} => $new_data->{$k}" );
        }
        $data->{$k} = $new_data->{$k};
    }

    if ( $data->{assay_results} ) {
        push @{ $data->{assay_results} }, @{ $new_data->{assay_results} };
    }

    if ( $new_data->{assay_pending} ) {
        unless ( $data->{assay_pending} and $data->{assay_pending} le $new_data->{assay_pending} ) {
            $data->{assay_pending} = $new_data->{assay_pending};
        }
    }

    if ( $new_data->{assay_complete} ) {
        unless ( $data->{asasy_complete} and $data->{assay_complete} ge $new_data->{assay_complete} ) {
            $data->{assay_complete} = $new_data->{assay_complete};
        }
    }
}

sub parse_oracle_date {
    my ( $self, $maybe_date ) = @_;

    LIMS2::HTGT::Migrate::Utils::parse_oracle_date( $maybe_date );
}

sub trim {
    my ( $self, $str ) = @_;    
    LIMS2::HTGT::Migrate::Utils::trim( $str );
}

__PACKAGE__->meta->make_immutable;

1;

__END__




