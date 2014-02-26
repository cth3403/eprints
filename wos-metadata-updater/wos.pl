#!/opt/csw/bin/perl -w -I/eprints/eprints3/perl_lib

use strict;
use warnings;
use EPrints;
use Getopt::Long;
use HTML::Entities;
use HTTP::Cookies;
use XML::LibXML;
# use the +trace => 'all' for debugging
# use SOAP::Lite +trace =>'all';
use SOAP::Lite;
use Data::Dumper;


# endpoints & namepsaces 
our $AUTH_ENDPOINT = "http://search.webofknowledge.com/esti/wokmws/ws/WOKMWSAuthenticate";
our $AUTH_NS = "http://auth.cxf.wokmws.thomsonreuters.com";
our $ISI_ENDPOINT = "http://search.webofknowledge.com/esti/wokmws/ws/WokSearch";
our $ISI_NS = "http://woksearch.v3.wokmws.thomsonreuters.com";

# Begin authorisation setup
# need a cookie to store the Session ID
my $authCook = HTTP::Cookies->new();
my $authSoap = SOAP::Lite->new();
$authSoap->proxy( $AUTH_ENDPOINT);
$authSoap->on_action( sub { qq() } );
$authSoap->on_fault( sub { print STDERR "Error: ".$_[1]->faultstring } );
$authSoap->autotype(0);
$authSoap->readable(1);
$authSoap->ns( $AUTH_NS, );
$authSoap->transport->cookie_jar( $authCook );
my $sid;
# End of authorisation setup

# Begin of main transport setup
my $soap = SOAP::Lite->new();
$soap->proxy( $ISI_ENDPOINT);
$soap->on_action( sub { qq() } );
$soap->on_fault( sub { print STDERR "Error: ".$_[1]->faultstring } );
$soap->autotype(0);
$soap->readable(1);
$soap->ns( $ISI_NS,'woksearch') ;
#End of main transport setup

# use prefined filters located in archive/[repostory_name]/cfg/cfg.d
my $searchconf = $session->get_repository->get_conf( "wos", "filters" );
my $query_builder = $session->get_repository->get_conf( "wos", "build_query" );

# Run authorisation subroutine
&authSess; 

# lets get updating
if( scalar(@idlist) ){
	my $list = EPrints::List->new(
					session => $session,
					dataset => $dataset,
					ids => \@idlist
					);
	$list->map(\&update_eprint);
	$list->dispose;
}
elsif( defined $searchconf ){
	my $ds = $session->get_repository->get_dataset( "eprint" );
	my $searchexp = EPrints::Search->new(
						session => $session,
						dataset => $ds,
						);
																
	# this sets the user that has the eprints to search WoS for 
	# in this case we are limiting our search to user number 6201
	$searchexp->add_field( $ds->get_field( "userid" ), 6201 );

	my $list = $searchexp->perform_search;
	
	if( $list->count == 0 ){
		print STDERR "The configured filters didn't match anything.\n"
		if $noise;
	}
	else {
		$list->map(\&update_eprint);
	}
	$list->dispose;
}

FINISH:

# run the close session subroutine
&closeSess;

$session->terminate;

sub update_eprint
{
my( $session, $dataset, $eprint ) = @_;

# exit if eprint isn't set or if the eprint does have something set in the wos_id field
return unless defined $eprint;
return unless defined $eprint->get_value("wos_id");

# set the query parameters for this eprint
my $query = &$query_builder( $eprint );
print STDERR $eprint->get_id.": searching for '$query'\n"
if $noise > 1;

# sleep a bit - try to stop from being throttled
sleep(int(rand(4)));

# attach our SID cookie 
$soap->transport->http_request->header( "Cookie" => "SID=\"" . $sid."\"" );

# set the search parameters for the search
my @search_params = (SOAP::Data->name( "databaseId" => "WOS" ),	SOAP::Data->name('uid'=> $query),SOAP::Data->name('queryLanguage')->value('en'),
								SOAP::Data->name('retrieveParameters' => \SOAP::Data->value(
								SOAP::Data->name('firstRecord')->value('1'),
								SOAP::Data->name('count')->value('1'))));
									
# ISI requires every argument be included, even if it's blank
my $som;

# begin the search and if this fails, print a warning
eval {
	$som = $soap->retrieveById( @search_params);
	1;
}
or do {
	$eprint->warning( "Unable to connect to the search service for EPrints ID " . $eprint->get_id . ": " . $@ );
	return undef;
};

# if we get back a fault from WoS
if( $som->fault ) {
	print STDERR "\tError from SOAP endpoint: ".$som->fault->{ faultstring }."\n";
	return;
}

# assign the result and create arrays for record processing
my $result =$som->result;
my $total = $result->{recordsFound};
my @records;
my @creators;
my @edb;
my @EPcreators;

# get the current eprint creators, we need the ID's which is the email address as this isn't always returned
push @EPcreators, @{$eprint->get_value("creators")};

# return with an error if we have no matches or more than 1
if( $total == 0 ) {
	print STDERR "\tNo matches found, ignoring.\n"
	if $noise > 1;
	return;
}
if( $total > 1 ) {
	print STDERR "\tMatched more than once, ignoring.\n"
	if $noise > 1;
	return;
}

# parse the xml result
my $doc = EPrints::XML::parse_xml_string( $result->{records} );

# make sure we only get one result at a time
foreach my $node ( $doc->documentElement->childNodes ) {
	next unless EPrints::XML::is_dom( $node, "Element" );
	my ($record) = {
		eprintid => $eprint->get_id,
		type => $eprint->get_type,
	};
	
# get the creators
# check to see if they are part of the creators already set in the eprint,
# if they are retrieve the ID and push to the creators array.
# if not just push them to the creators array. This maintains the order in
# which they are retrieved from WoS
foreach my $sum ( $doc->getElementsByTagName("summary" ) ) {
	foreach my $names ( $sum->getElementsByTagName("names") ) {
		foreach my $au ( $names->getElementsByTagName( "name" ) ) {
			my $match = 0;
			if( $au->getAttribute( "seq_no" ) eq "1" && $au->getAttribute( "role" ) eq "author" ) {
				my ($count) = $au->parentNode;
				$record->{count} = $count->getAttribute( "count" );
				my $role = $au->getAttribute( "role" );
				my $last_name = $au->getElementsByTagName( "last_name" );
				my $first_name = $au->getElementsByTagName( "first_name" );
				utf8::encode($last_name);
				utf8::encode($first_name);
				my $newStr = substr($first_name, 0, 1);
				my $id;
				my $family;
				my $given;
				foreach my $hash ( @EPcreators ){
					$match = 0;
					$family = $hash->{name}{family};
					$given = $hash->{name}{given};
					my $strG = substr($given,0,1);
					if( $family eq $last_name && $strG eq $newStr ){
						$match = 1;
						$id = $hash->{id};
						last;	
					}
				}
				if( $match eq 0 ) {
					push @creators, { name => { family => $last_name, given => $first_name}};
				}
				if( $match eq 1 ) {
					push @creators, { name => { family => $last_name, given => $first_name}, id => $id};
				}
				if( $match > 1 ) {
					push @creators, { name => { family => $last_name, given => $first_name}};
				}
			}
			if( $au->getAttribute( "seq_no" ) > "1" && $au->getAttribute( "role" ) eq "author" ) {
				my $role = $au->getAttribute( "role" );
					foreach my $author ( $au ){
						my $last_name = $author->getElementsByTagName( "last_name" );
						my $first_name = $author->getElementsByTagName( "first_name" );
						utf8::encode($last_name);
						utf8::encode($first_name);
						my $newStr = substr($first_name, 0, 1);
						my $id;
						my $family;
						my $given;
						foreach my $hash ( @EPcreators ) {
							$match = 0;
							$family = $hash->{name}{family};
							$given = $hash->{name}{given};
							my $strG = substr($given,0,1);
							if($family eq $last_name && $strG eq $newStr){
								$match = 1;
								$id = $hash->{id};
								last;
							}
						}
						if( $match eq 0 ) {
							push @creators, { name => { family => $last_name, given => $first_name}};
						}
						if( $match eq 1 ) {
							push @creators, { name => { family => $last_name, given => $first_name}, id => $id};
						}
						if( $match > 1 ) {
							push @creators, { name => { family => $last_name, given => $first_name}};
						}
					}
				}
				if( $au->getAttribute( "seq_no" ) eq "1" && $au->getAttribute( "role" ) eq "book_editor" ){
					my ($count) = $au->parentNode;
					$record->{count} = $count->getAttribute( "count" );
					my $role = $au->getAttribute( "role" );
					my $last_name = $au->getElementsByTagName( "last_name" );
					my $first_name = $au->getElementsByTagName( "first_name" );
					utf8::encode($last_name);
					utf8::encode($first_name);
					my $newStr = substr($first_name, 0, 1);
					my $id;
					my $family;
					my $given;
					foreach my $hash ( @EPcreators ){
						$match = 0;
						$family = $hash->{name}{family};
						$given = $hash->{name}{given};
						my $strG = substr($given,0,1);
						if( $family eq $last_name && $strG eq $newStr ) {
							$match = 1;
							$id = $hash->{id};
							last;
						}
					}
					if( $match eq 0 ){
						push @creators, { name => { family => $last_name, given => $first_name}};
					}
					if( $match eq 1 ){
						push @creators, { name => { family => $last_name, given => $first_name}, id => $id};
					}
					if( $match > 1 ){
						push @creators, { name => { family => $last_name, given => $first_name}};
					}
				}
				if( $au->getAttribute( "seq_no" ) > "1" && $au->getAttribute( "role" ) eq "book_editor" ){
					my $role = $au->getAttribute( "role" );
					foreach my $editor ( $au ){
						my $last_name = $editor->getElementsByTagName( "last_name" );
						my $first_name = $editor->getElementsByTagName( "first_name" );
						utf8::encode($last_name);
						utf8::encode($first_name);
						my $newStr = substr($first_name, 0, 1);
						my $id;
						my $family;
						my $given;
						foreach my $hash ( @EPcreators ){
							$match = 0;
							$family = $hash->{name}{family};
							$given = $hash->{name}{given};
							my $strG = substr($given,0,1);
							if( $family eq $last_name && $strG eq $newStr ){
								$match = 1;
								$id = $hash->{id};
								last;
							}
						}
						if( $match eq 0 ){
							push @creators, { name => { family => $last_name, given => $first_name}};
						}
						if( $match eq 1 ){
							push @creators, { name => { family => $last_name, given => $first_name}, id => $id};
						}
						if( $match > 1 ){
							push @creators, { name => { family => $last_name, given => $first_name}};
						}
					}
				}
				if( $au->getAttribute( "role" ) eq "publisher" ) {
					my $role = $au->getAttribute( "role" );
					$record->{publisher} = $au->getElementsByTagName( "display_name" );
					utf8::encode($record->{publisher});
				}
			}
		}
	}
	# end of get creators

	# get the publisher details
	foreach my $publisher ( $node->getElementsByTagName( "publisher" ) ) {
		foreach my $pub_addr ( $publisher->getElementsByTagName( "address_spec" ) ) {
			$record->{pub_place} = $pub_addr->getElementsByTagName( "city" );
			utf8::encode($record->{pub_place});
		}
	}

	# get the title information etc.
	foreach my $item( $node->getElementsByTagName( "title" ) ) {
		foreach my $attr ( $item->attributes() ) {
			if( $attr->value eq "item" ) {
				$record->{title} = $item->textContent;
				utf8::encode($record->{title});
			}
			if( $attr->value eq "series" ) {
				$record->{series} = $item->textContent;
				utf8::encode($record->{series});
			}
			if( $attr->value eq "source" ) {
				$record->{source} = $item->textContent;
				utf8::encode($record->{source});
			}
		}
	}
	
	# get the doi, isbn, issn
	foreach my $ident ( $node->getElementsByTagName( "identifier" ) ) {
		foreach my $attr ( $ident->attributes() ) {
			if( $attr->value eq "doi" ) {
				$record->{doi} = $ident->getAttribute( "value" );
			}
			if( $attr->value eq "issn" ) {
				$record->{issn} = $ident->getAttribute( "value" );
			}
			if( $attr->value eq "isbn" ) {
				$record->{isbn} = $ident->getAttribute( "value" );
			}
		}
	}
	
	# get pub info (date, volume, issue)
	my( $pub ) = $node->getElementsByTagName( "pub_info" );
	if( $pub->hasAttribute("sortdate") eq 1 ) {
		$record->{year} = $pub->getAttribute( "sortdate" );
	}
	if( $pub->hasAttribute("pubtype") eq 1 ) {
		$record->{pubtype} = $pub->getAttribute( "pubtype" );
	}
	if( $pub->hasAttribute("vol") eq 1 ) {
		$record->{vol} = $pub->getAttribute( "vol" );
	}
	if( $pub->hasAttribute("issue") eq 1 ) {
		$record->{issue} = $pub->getAttribute( "issue" );
	}
	
	# get page information
	if($node->getElementsByTagName( "page" ) ) {
		my( $page ) = $node->getElementsByTagName( "page" );
		foreach my $pageAtt ( $page->attributes() ) {
			$record->{page_begin} = $page->getAttribute( "begin" );
			$record->{page_end} = $page->getAttribute( "end" );
			$record->{page_count} = $page->getAttribute( "page_count" );
		}
		$record->{page_range} = $page->textContent;
	}
	
	# get conference information
	if($node->getElementsByTagName( "conferences" ) ) {
		foreach my $conf ( $node->getElementsByTagName( "conference" ) ) {
			$record->{confName} = $conf->getElementsByTagName( "conf_info" );
			utf8::encode($record->{confName});
			$record->{confDate} = $conf->getElementsByTagName( "conf_date" )->string_value();
		}
	}
	
	# push the details to the the records array
	push(@records, ($record, @creators));
}

# retrieve the first element from the records array
my $record = $records[0];

# use the below statement to print info about the retrieved item
# print Data::Dumper->Dump([$record, [qw(record)]]);

# add 'MATCHED -- ' to the title to indicate that the information is the result of the script.
# deactivate this for live data
my $matched = "MATCHED -- ";
$matched .= $record->{title}; 

# set the corresponding eprint values to the retrieved information 
$eprint->set_value("title", $matched);
$eprint->set_value("creators", \@creators );
$eprint->set_value( "publisher",$record->{publisher} );
$eprint->set_value( "place_of_pub",$record->{pub_place} );
$eprint->set_value( "date_type", "published" );
$eprint->set_value( "ispublished", "pub");
$eprint->set_value( "id_number", $record->{doi} );
$eprint->set_value( "series",$record->{series});
$eprint->set_value( "publication", $record->{source} );
$eprint->set_value( "issn",$record->{issn} );
$eprint->set_value( "isbn",$record->{isbn} );
$eprint->set_value( "date",$record->{year} );
$eprint->set_value( "volume",$record->{vol} );
$eprint->set_value( "number",$record->{issue} );
$eprint->set_value( "pagerange",$record->{page_range} );
$eprint->set_value( "event_title",$record->{confName} );
$eprint->set_value( "event_location",$record->{confName} );

# commit the changes to the eprint
$eprint->commit;
}

# the authorisation sub routine
sub authSess{

# set the SOAP data and call the service
my $search = SOAP::Data->name('authenticate');			
my $som = $authSoap->call('authenticate');

# if an error, print the message. Else return the result to the cookie variable
if( $som->fault ){		
	print STDERR "\tError from SOAP endpoint: ".$som->fault->{ faultstring }."\n";
	return;
}
else{
	$sid = $som->result;
}
}

# close session sub routine
sub closeSess{

#set the header type
$authSoap->transport->http_request->header( "Cookie" => "SID=\"" . $sid. "\";" );

# call the service
my $cls = $authSoap->call('closeSession');
}
