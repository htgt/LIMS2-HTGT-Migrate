package LIMS2::HTGT::Migrate::PlateData;

use Moose;
use LIMS2::HTGT::Migrate::Utils qw( 
                                    format_well_name
                                    is_consistent_design_instance
                                    canonical_username
                                    canonical_datetime
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

has limit => (
    is     => 'ro',
    isa    => 'Maybe[Int]',
);

has plate_names => (
    is => 'ro',
    isa => 'ArrayRef',
    default => sub { [] },
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

has lims2_plate_type => (
    is       => 'ro',
    isa      => 'Str',
    init_arg => undef
);

has 'plate_name_regex' => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    default  => undef,
);

has process_type => (
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
        'me.type' => $self->plate_type,
    );

    if ( $self->limit ) {
        $search{rownum} = { '<=', $self->limit };
    }

    if ( @{ $self->plate_names } ) {
        $search{'name'} = { 'IN', $self->plate_names };
    }
    elsif ( $self->plate_name_regex ) {
        $search{'name'} = { 'LIKE' => $self->plate_name_regex };
    }

    if ( $self->created_after ) {
        $search{'me.created_date'} = { '>', $self->created_after };
        
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
        $self->log->debug('Dumping plate data');
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
        name        => $plate->name,
        type        => $self->lims2_plate_type,
        species     => 'Mouse',
        description => $plate->description || '',
        created_by  => canonical_username( $plate->created_user ),
        created_at  => canonical_datetime( $self->created_date ),
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
    
    return \%data;
}

sub plate_comments {
    my ( $self, $plate ) = @_;

    my @comments;

    for my $c ( $plate->plate_comments ) {
        push @comments, {
            comment_text => $c->plate_comment,
            created_by   => canonical_username( $c->edit_user ),
            created_at   => canonical_datetime( $c->edit_date ),
        }
    }

    return \@comments;
}

sub wells {
    my ( $self, $plate ) = @_;

    my @well_data;
    for my $well ( $plate->wells ) {
        my $well_data = $self->well_data( $well );
        push @well_data, $well_data if $well_data;
    }
    return \@well_data;
}

sub well_data {
    my ( $self, $well ) = @_;
    
    $self->init_htgt_well_data( $well );

    return unless defined $well->design_instance_id;
    
    my %data = (
        well_name => format_well_name( $well->well_name ),
        #comments  => $self->well_comments( $well ),
        process_type => $self->process_type,
    );
    
    return \%data;
}

sub well_comments {
    my ( $self, $well ) = @_;

    my @comments;
    for my $c ( grep { $_->data_type =~ m/comments?/i } $self->htgt_well_data ) {
        push @comments, {
            created_at   => canonical_datetime( $c->edit_date ),
            created_by   => canonical_username( $c->edit_user) || $self->migrate_user,
            comment_text => $self->trim( $c->data_value )
        };
    }

    return \@comments;
}

sub parent_well {
    my ( $self, $well ) = @_;
    
    if ( $well->parent_well_id ) {
        my $parent_well = $well->parent_well;
        if ( is_consistent_design_instance( $well, $parent_well ) ) {
            return {
                plate_name => $parent_well->plate->name,
                well_name  => $parent_well->well_name
            };
        }
        else {            
            $self->log->warn( "$well design instance mismatch" );
        }
    }

    return;
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




