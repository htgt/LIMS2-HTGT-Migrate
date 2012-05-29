#!/usr/bin/env perl

use strict;
use warnings FATAL => 'all';

use HTGT::DBFactory;
use YAML::Any;
use Const::Fast;

const my %IS_WANTED_COLUMN => map { $_ => 1 } qw( EDIT_USER EDITED_USER CREATED_USER );

sub list_tables {
    my ( $dbh, $schema_name ) = @_;
    
    my $sth = $dbh->table_info( undef, $schema_name, undef, 'TABLE' );

    my @table_names;

    while ( my $r = $sth->fetchrow_hashref ) {
        push @table_names, $r->{TABLE_NAME};
    }
    
    return \@table_names
}

sub list_columns {
    my ( $dbh, $schema_name, $table_name ) = @_;

    my @columns;
    
    my $sth = $dbh->column_info( undef, $schema_name, $table_name, undef );
    while ( my $r = $sth->fetchrow_hashref ) {
        push @columns, uc $r->{COLUMN_NAME};
    }

    return \@columns;
}

my $dbh = HTGT::DBFactory->dbi_connect( 'eucomm_vector' );

my @queries = ( 'select auth_user_name from auth_user' );

my $tables = list_tables( $dbh, 'EUCOMM_VECTOR' );

for my $table ( @{$tables} ) {
    for my $column ( grep { exists $IS_WANTED_COLUMN{$_} } @{ list_columns( $dbh, 'EUCOMM_VECTOR', $table ) } ) {
        push @queries, sprintf( 'select %s from %s where %s is not null',
                                $dbh->quote_identifier( $column ),
                                $dbh->quote_identifier( $table ),
                                $dbh->quote_identifier( $column )
                            );
    }
}

my $sth = $dbh->prepare( join "\nUNION\n", @queries );
$sth->execute;

while ( my ( $user_name ) = $sth->fetchrow_array ) {
    print Dump( { user_name => $user_name } );
}
