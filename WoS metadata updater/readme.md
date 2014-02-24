# README

### Web of Science eprints metadata downloader

#### Summary
============

This perl script takes a Web of Science ID from a specified eprint(s) and retrieves the metadata held by Web of Science for this ID.


#### Requirements:

First and foremost you need an active subscription to WoS.

The following perl modules need to be installed:

Getopt::Long   
Pod::Usage  
HTML::Entities  
HTTP::Cookies  
XML::LibXML  
SOAP::Lite  
Data::Dumper

You need to create a field to hold the WOS ID, this field is used to construct the search (see this <a href="http://wiki.eprints.org/w/HOW_TO:_Add_a_New_Field">HOWTO</a>). Alternatively change the search filters to the field name where the WoS ID is stored.

#### Usage:

You can either have the script work on all eprints attached to a user or supply a list of ids to work upon.

e.g. ./wos.pl [archive] [eprint ids]

You will need to place the search configuration file (zz_wos.pl) in:  
archive/cfg/cfg.d


#### Limitations:

We have IP authentication and so we don't send our username and password as part of the authorisation process. Please see the Thomson Reuters documentation for the fields the authorisation service expects.
