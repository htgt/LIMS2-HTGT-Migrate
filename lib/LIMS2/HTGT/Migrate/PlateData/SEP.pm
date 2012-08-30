package LIMS2::HTGT::Migrate::PlateData::SEP;

use Moose;
use namespace::autoclean;

extends 'LIMS2::HTGT::Migrate::PlateData';

has '+plate_type' => (
    default => 'EP'
);

has '+lims2_plate_type' => (
    default => 'SEP'
);

has '+process_type' => (
    default => 'second_electroporation'
);

override well_data => sub {
    my ( $self, $well ) = @_;
    my $data = super();
    return unless $data;

    my $parent_wells = $self->sep_input_wells( $well );

    $data->{dna_plate} = $parent_wells->{dna_plate};
    $data->{dna_well} = $parent_wells->{dna_well};
    $data->{xep_plate} = $parent_wells->{xep_plate};
    $data->{xep_well} = $parent_wells->{xep_well};
    
    return $data;
};

sub sep_input_wells {
    my ( $self, $well ) = @_;
    my %sep_input_wells;

    my $parent_well = $self->parent_well( $well );

    $sep_input_wells{dna_plate} = $parent_well->{plate_name};
    $sep_input_wells{dna_well}  = $parent_well->{well_name};

    # first allele input is frm xep plate, the well locations for a
    # sep and xep plate should match up
    $sep_input_wells{xep_plate} = $self->xep_plate_name( $well->plate );
    $sep_input_wells{xep_well}  = substr( $well->well_name, -3);

    return \%sep_input_wells;
}

sub xep_plate_name {
    my ( $self, $plate ) = @_;

    my $plate_name = $plate->name;

    $plate_name =~ s/SEP/XEP/;

    return $plate_name;
}

__PACKAGE__->meta->make_immutable;

1;

__END__
