package LIMS2::HTGT::Migrate::PlateData::XEP;

use Moose;
use namespace::autoclean;

extends 'LIMS2::HTGT::Migrate::PlateData';

#No XEP plates in htgt, need to work out XEP plate information from SEP plates
has '+plate_type' => (
    default => 'EP'
);

has '+plate_name_regex' => (
    default => 'SEP%'
);

has '+lims2_plate_type' => (
    default => 'XEP'
);

has '+process_type' => (
    default => 'recombinase'
);


override plate_data => sub {
    my ( $self, $plate ) = @_;
    my $data = super();

    $data->{description} = '';
    $data->{comments} = [];
    $data->{name} = $self->xep_plate_name( $plate );
    $data->{created_by} = 'htgt_migrate';

    return $data;
};

override well_data => sub {
    my ( $self, $well ) = @_;
    my $data = super();
    return unless $data;

    my $parent_well = $self->find_fep_parent_well( $well );
    $data->{parent_plate} = $parent_well->{plate_name};
    $data->{parent_well}  = $parent_well->{well_name};

    $data->{recombinase} = [ 'Flp' ];
    
    return $data;
};

sub xep_plate_name {
    my ( $self, $plate ) = @_;

    my $plate_name = $plate->name;

    $plate_name =~ s/SEP/XEP/;

    return $plate_name;
}

sub fep_plate_name {
    my ( $self, $plate ) = @_;

    my $plate_name = $plate->name;

    $plate_name =~ s/SEP/FEP/;

    return $plate_name;
}

sub find_fep_parent_well {
    my ( $self, $well ) = @_;

    my $fep_plate_name = $self->fep_plate_name( $well->plate );
    my $design_instance_id = $well->design_instance_id;


    my @parent_wells = $self->schema->resultset( 'Well' )->search(
        {
            'plate.name'   => $fep_plate_name,
            'me.design_instance_id' => $design_instance_id,
        },
        {
            join => [ 'plate' ],
        }
    );

    my $count = @parent_wells;
    if ( $count > 1 ) {
        die "Cannot work out xep well parent on fep plate $fep_plate_name"
            . " we have $count wells with the same design ";
    }

    unless ( $count ) {
        # lets see if the well in same location hits the same gene?
        my $well_name = substr( $well->well_name, -3 );
        my $parent_well = $self->schema->resultset( 'Well' )->find(
            {
                'plate.name' => $fep_plate_name,
                'me.well_name' => { LIKE => '%' . $well_name },
            },
            {
                join => [ 'plate' ]
            }
        );

        die("No well in same position or with same design instance on fep plate $fep_plate_name")
            unless $parent_well;
        
        my $gene = $well->design_instance->design->info->mgi_gene->marker_symbol;
        my $parent_gene = $parent_well->design_instance->design->info->mgi_gene->marker_symbol;
        if ( $gene eq $parent_gene ) {
            push @parent_wells, $parent_well;
        }
    }

    return {
        plate_name => $parent_wells[0]->plate->name,
        well_name  => substr( $parent_wells[0]->well_name, -3),
    };
}

__PACKAGE__->meta->make_immutable;

1;

__END__
