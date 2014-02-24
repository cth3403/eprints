# this field is used to store the ISI citation data

# filters to apply to eprints before searching for them in ISI
# remove to look for all or specify with spaces e.g. "article conference_item"
$c->{tulip}->{filters} = [
        { meta_fields => [qw( type )], merge => "ANY", value => "article conference_item" },
];

# return a ISI search query string in UTF-8 based on $eprint
# return undef if we can't build a query
$c->{tulip}->{build_query} = sub
{
        my( $eprint ) = @_;

        return unless $eprint->is_set( "wos_id" ) ;

        my $title = $eprint->get_value( "wos_id" );

        my $query = $title;

        return $query;
};