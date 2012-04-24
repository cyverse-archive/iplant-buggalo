package IPlant::Buggalo;

use 5.006;
use strict;
use warnings;

use Apache2::Const -compile => qw(:common :http);
use Apache2::Request;
use Apache2::RequestIO;
use Apache2::RequestRec;
use Apache2::RequestUtil;
use Apache2::Response;
use Apache2::ServerUtil;
use Carp;
use Config;
use English qw(-no_match_vars);
use File::Basename;
use HTTP::Request;
use HTTP::Request::Common;
use IPlant::Clavin;
use JSON;
use LWP::UserAgent;
use Readonly;
use URI::Escape;

use version; our $VERSION = qv('0.4.1');

# Values used to retrieve configuration settings.
Readonly my $ZOOKEEPER_PARM => 'zookeeper';
Readonly my $SERVICE_NAME   => 'buggalo';

# The configuration parameters supported by this handler.
Readonly my %CONFIG_PARM_FOR => (
    'nibblonian-prefix=s' => 'buggalo.nibblonian-prefix',
    'scruffian-prefix=s'  => 'buggalo.scruffian-prefix',
    'tree-parser-url=s'   => 'buggalo.tree-parser-url',
    'accepted-formats=a'  => 'buggalo.accepted-tree-formats',
);

# The actual configuration settings; these will only be loaded once.
my %config;

# The handlers for various HTTP methods.
Readonly my %HANDLER_METHOD_FOR => (
    'GET'  => \&_get_request,
    'POST' => \&_post_request,
);

##########################################################################
# Usage      : $status = handler($r);
#
# Purpose    : Handles an HTTP request.
#
# Returns    : The response status code.
#
# Parameters : $r - the Apache request object.
#
# Throws     : "CONFIGURATION ERROR: missing $ZOOKEEPER_PARM perl var"
#              "CONFIGURATION ERROR: services not allowed on this host"
#              "INTERNAL ERROR: unrecognized configuration type"
#              "CONFIGURATION ERROR: missing $name config parameter"
sub handler {
    my ($r) = @_;
    _init($r);
    my $response = eval { _handle_request($r); 1 };
    return _error_response( $r, $EVAL_ERROR ) if !defined $response;
    return Apache2::Const::OK;
}

##########################################################################
# Usage      : _init($r);
#
# Purpose    : Initializes the configuration settings if they haven't been
#              initialized already.  This initialization strategy means
#              that this handler can currently only be used in one web
#              application per server.
#
# Returns    : Nothing.
#
# Parameters : $r - the Apache request object.
#
# Throws     : "CONFIGURATION ERROR: missing $ZOOKEEPER_PARM perl var"
#              "CONFIGURATION ERROR: services not allowed on this host"
#              "INTERNAL ERROR: unrecognized configuration type"
#              "CONFIGURATION ERROR: missing $name config parameter"
sub _init {
    my ($r) = @_;
    return if %config;
    %config = _load_config($r);
    return;
}

##########################################################################
# Usage      : %config = _load_config($r);
#
# Purpose    : Loads the configuration settings from Zookeeper.
#
# Returns    : the configuration settings.
#
# Parameters : $r - the Apache request object.
#
# Throws     : "CONFIGURATION ERROR: missing $ZOOKEEPER_PARM perl var"
#              "CONFIGURATION ERROR: services not allowed on this host"
#              "INTERNAL ERROR: unrecognized configuration type"
#              "CONFIGURATION ERROR: missing $name config parameter"
sub _load_config {
    my ($r) = @_;

    # Fetch the zookeeper connection string.
    my $zookeeper = $r->dir_config($ZOOKEEPER_PARM);
    croak "CONFIGURATION ERROR: missing $ZOOKEEPER_PARM perl var"
        if !defined $zookeeper;

    # Retrieve the configuration settings.
    my $clavin_ref = IPlant::Clavin->new( { zk_hosts => $zookeeper } );
    croak "CONFIGURATION ERROR: services not allowed on this host"
        if !$clavin_ref->can_run();
    my $props_ref = $clavin_ref->properties($SERVICE_NAME);

    return map { _config_parm( $props_ref, $_ ) } keys %CONFIG_PARM_FOR;
}

##########################################################################
# Usage      : ( $name, $value ) = _config_parm( $props_ref, $desc );
#
# Purpose    : Extracts a configuration parameter from the configuration
#              settings.
#
# Returns    : The internal configuration parameter name and value.
#
# Parameters : $props_ref - a reference to the configuration properties.
#              $desc      - the configuration parameter descriptor.
#
# Throws     : "INTERNAL ERROR: unrecognized configuration type"
#              "CONFIGURATION ERROR: missing $name config parameter"
sub _config_parm {
    my ( $props_ref, $desc ) = @_;

    # Extract the internal name and configuration parameter type.
    my ( $name, $type ) = split m/=/xms, $desc, 2;

    # Determine how to extract the parameter.
    my $getter_ref
        = $type eq 's' ? \&_scalar_config_parm
        : $type eq 'a' ? \&_array_config_parm
        :                undef;
    croak "INTERNAL ERROR: unrecognized configuration type: $type"
        if !defined $getter_ref;

    # Return the internal parameter name and value.
    return ( $name, $getter_ref->( $props_ref, $name ) );
}

##########################################################################
# Usage      : $value = _scalar_config_parm( $props_ref, $internal_name );
#
# Purpose    : Extracts the value of a scalar configuration parameter from
#              the configuration settings.
#
# Returns    : The configuration parameter value.
#
# Parameters : $props_ref     - a reference to the configuration settings.
#              $internal_name - the internal configuration parameter name.
#
# Throws     : "CONFIGURATION ERROR: missing $name config parameter"
sub _scalar_config_parm {
    my ( $props_ref, $internal_name ) = @_;

    # Get the external name for the parameter.
    my $name = $CONFIG_PARM_FOR{"$internal_name=s"};

    # Fetch the parameter value.
    my $value = $props_ref->{$name};
    croak "CONFIGURATION ERROR: missing $name config parameter"
        if !defined $value;

    return $value;
}

##########################################################################
# Usage      : $values_ref = _array_config_parm( $props_ref,
#                  $internal_name );
#
# Purpose    : Extracts teh value of an array configuration parameter from
#              the configuration settings.
#
# Returns    : The configuration parameter value.
#
# Parameters : $props_ref     - a reference to the configuration settings.
#              $internal_name - the internal configuration parameter name.
#
#
# Throws     : "CONFIGURATION ERROR: missing $name config parameter"
sub _array_config_parm {
    my ( $props_ref, $internal_name ) = @_;

    # Get the external name for the parameter.
    my $name = $CONFIG_PARM_FOR{"$internal_name=a"};

    # Fetch the parameter value.
    my $value = $props_ref->{$name};
    croak "CONFIGURATION ERROR: missing $name config parameter"
        if !defined $value;

    return [ split m/,\s*/xms, $value];
}

##########################################################################
# Usage      : $status_code = _error_response( $r, $error );
#
# Purpose    : Formats an appropriate response to an error and returns the
#              appropriate status code.  If the error happens to be a hash
#              then the status code is extracted from the hash.  Otherwise
#              the error code defaults to Apache2::Const::SERVER_ERROR.
#
# Returns    : the HTTP status code.
#
# Parameters : $r     - the Apache request object.
#              $error - the error.
#
# Throws     : No exceptions.
sub _error_response {
    my ( $r, $error ) = @_;

    # Extract the status code, message amd details from the error.
    my ( $status_code, $msg, $detail ) = _parse_error($error);

    # Write out the response.
    my $content = _json_from_scalar( _build_error_response( $msg, $detail ) );
    $r->content_type('application/json');
    $r->custom_response( $status_code, $content );

    return $status_code;
}

##########################################################################
# Usage      : ( $status, $msg, $detail ) = _parse_error($error);
#
# Purpose    : Determines the message, error details and HTTP status code
#              to use for the given error.
#
# Returns    : The status code and detail message.
#
# Parameters : $error - the error to parse.
#
# Throws     : No exceptions.
sub _parse_error {
    my ($error) = @_;
    my ( $status, $msg, $detail )
        = ref $error eq 'HASH'
        ? @{$error}{qw(status message detail)}
        : ( Apache2::Const::SERVER_ERROR, $error );
    return ( $status, $msg, $detail );
}

##########################################################################
# Usage      : $response_ref = _build_error_response( $error, $detail );
#
# Purpose    : Builds an error response containing the given error
#              message and error details.
#
# Returns    : The response.
#
# Parameters : $error  - the error message to include.
#              $detail - the detail information to include.
#
# Throws     : No exceptions.
sub _build_error_response {
    my ( $error, $detail ) = @_;
    my $response_ref = {
        'status'  => 'error',
        'message' => $error,
    };
    if ( defined $detail ) {
        $response_ref->{detail} = $detail;
    }
    return $response_ref;
}

##########################################################################
# Usage      : _handle_request($r);
#
# Purpose    : Handles an HTTP request.
#
# Returns    : Nothing.
#
# Parameters : $r - the Apache request object.
#
# Throws     : Errors in the form of a hash.
sub _handle_request {
    my ($r) = @_;

    # Determine which request method to use.
    my $method = $r->method();
    my $sub    = $HANDLER_METHOD_FOR{ $r->method() };
    croak _bad_request("unsupported method: $method")
        if !defined $sub;

    # Handle the request.
    $sub->($r);

    return;
}

##########################################################################
# Usage      : _get_request($r);
#
# Purpose    : Handles an HTTP GET request.
#
# Returns    : Nothing.
#
# Parameters : $r - the Apache request object.
#
# Throws     : Errors in the form of a hash.
sub _get_request {
    my ($r) = @_;

    # Get the query string parameters from the request.
    my $req = Apache2::Request->new($r);
    my ( $user, $path )
        = map { _get_required_param( $req, $_ ) } qw(user path);

    # Process the request.
    my $filename    = basename($path);
    my $contents    = _get_contents( $user, $path );
    my @trees       = _get_trees_in($contents);
    my $results_ref = _get_urls_for( $filename, @trees );
    _update_tree_urls( $user, $path, $results_ref );

    # Send the response.
    $r->content_type('application/json');
    $r->print( _build_final_response($results_ref) );

    return;
}

##########################################################################
# Usage      : _post_request($r);
#
# Purpose    : Handles an HTTP POST request.
#
# Returns    : Nothing.
#
# Parameters : $r - the Apache request object.
#
# Throws     : Errors in the form of a hash.
sub _post_request {
    my ($r) = @_;

    # Slurp in the contents of the request body.
    my $contents = _read_request_body($r);

    # Process the request.
    my @trees = _get_trees_in($contents);
    my $results_ref = _get_urls_for( 'stdin', @trees );

    # Send the response.
    $r->content_type('application/json');
    $r->print( _build_final_response($results_ref) );

    return;
}

##########################################################################
# Usage      : $body = _read_request_body($r);
#
# Purpose    : Reads the body of the HTTP request.
#
# Returns    : The request body.
#
# Parameters : $r - the Apache request object.
#
# Throws     : No exceptions.
sub _read_request_body {
    my ($r) = @_;
    my $body;
    $r->read( $body, $r->headers_in()->{'content-length'} );
    return $body;
}

##########################################################################
# Usage      : $response = _build_final_response($results_ref);
#
# Purpose    : Builds the final response to send to the caller.
#
# Returns    : The final response as a JSON string.
#
# Parameters : $results_ref - the results of obtaining the tree URLs.
#
# Throws     : No exceptions.
sub _build_final_response {
    my ($results_ref) = @_;
    $results_ref->{action} = 'tree_manifest';
    return _json_from_scalar($results_ref);
}

##########################################################################
# Usage      : _update_tree_urls( $user, $path, $request_body_ref );
#
# Purpose    : Updates the tree URLs for the file at the given location.
#
# Returns    : Nothing.
#
# Parameters : $user             - the username.
#              $path             - the path to the file.
#              $request_body_ref - the body of the request.
#
# Throws     : Errors in the form of a hash.
sub _update_tree_urls {
    my ( $user, $path, $request_body_ref ) = @_;
    _delete_old_urls( $user, $path );
    _add_new_urls( $user, $path, $request_body_ref );
    return;
}

##########################################################################
# Usage      : _delete_old_urls( $user, $path, $request_body_ref );
#
# Purpose    : Deletes the old URLs that are associated with the file.
#
# Returns    : Nothing.
#
# Parameters : $user             - the username.
#              $path             - the path to the file.
#              $request_body_ref - the body of the request.
#
# Throws     : No exceptions.
#
# Comments   : Nibblonian currently returns a 500 status code if the file
#              doesn't have any tree URLs associated with it.  This
#              subroutine currently ignores the response code from
#              Nibblonian for this reason.
sub _delete_old_urls {
    my ( $user, $path, $request_body_ref ) = @_;

    # Send the request.
    my $address = _nibblonian_address( '/file/metadata', $user, $path );
    $address .= '&attr=tree-urls';
    my $user_agent = LWP::UserAgent->new();
    my $request    = HTTP::Request->new( 'DELETE', $address );
    my $response   = $user_agent->request($request);

    return;
}

##########################################################################
# Usage      : _add_new_urls( $user, $path, $request_body_ref );
#
# Purpose    : Adds the new URLs to the list of tree URLs associated with
#              the file.
#
# Returns    : Nothing.
#
# Parameters : $user             - the username.
#              $path             - the path to the file.
#              $request_body_ref - the body of the request.
#
# Throws     : Errors in the form of a hash.
sub _add_new_urls {
    my ( $user, $path, $request_body_ref ) = @_;

    # Send the request.
    my $address    = _nibblonian_address( '/file/tree-urls', $user, $path );
    my $user_agent = LWP::UserAgent->new();
    my $response   = $user_agent->request(
        POST $address,
        Content_Type => 'application/json',
        Content      => _json_from_scalar($request_body_ref),
    );
    croak _metadata_update_error($response) if !$response->is_success();

    return;
}

##########################################################################
# Usage      : my $json = _json_from_scalar($scalar_ref);
#
# Purpose    : Converts a scalar to a JSON string.  Hash references are
#              converted to JSON objects; array references are converted
#              to JSON arrays.
#
# Returns    : the JSON string.
#
# Parameters : $scalar_ref - a reference to the scalar to convert.
#
# Throws     : No exceptions.
sub _json_from_scalar {
    my ($scalar_ref) = @_;
    my $json = JSON->new()->allow_nonref();
    return $json->encode($scalar_ref);
}

##########################################################################
# Usage      : $scalar_ref = _scalar_from_json($content);
#
# Purpose    : Converts a JSON string to a scalar reference.  JSON objects
#              are converted to hash references; JSON arrays are converted
#              to array references.
#
# Returns    : The scalar reference.
#
# Parameters : $content - the JSON string to convert.
#
# Throws     : No exceptions.
sub _scalar_from_json {
    my ($content) = @_;
    my $json = JSON->new()->allow_nonref();
    return $json->decode($content);
}

##########################################################################
# Usage      : $results_ref = _get_urls_for( $filename, @trees );
#
# Purpose    : Gets the tree URLs for each given tree,
#
# Returns    : a reference to a hash containing the URLs.
#
# Parameters : $filename - the name of the file.
#              @trees    - the list of trees found in the file.
#
# Throws     : Errors in the form of a hash.
sub _get_urls_for {
    my ( $filename, @trees ) = @_;

    # Determine the name prefix to use for unnamed trees.
    my $prefix = ( split m/[.]/xms, $filename, 2 )[0];

    # Get the URL for each tree in the list.
    my @results;
    my $tree_num = 0;
    for my $tree (@trees) {
        my ( $name, $newick ) = @{$tree};
        if ( !defined $name || $name =~ m/ \A \s* \z /xms ) {
            $name = "${prefix}_${tree_num}";
            $tree_num++;
        }
        my $url = _get_url_for( $name, $newick );
        push @results, { label => $name, url => $url };
    }

    return { 'tree-urls' => \@results };
}

##########################################################################
# Usage      : $url = _get_url_for( $name, $tree );
#
# Purpose    : Gets the URL for the given tree.
#
# Returns    : The URL returned by the tree viewer.
#
# Parameters : $name - the tree name.
#              $tree - the tree in Newick format.
#
# Throws     : Errors in the form of a hash.
sub _get_url_for {
    my ( $name, $tree ) = @_;

    # Fetch the URL.
    my $user_agent = LWP::UserAgent->new();
    my $response   = $user_agent->request(
        POST $config{'tree-parser-url'},
        Content_Type => 'form-data',
        Content      => [
            newickData => "$tree;",
            name       => $name,
        ],
    );
    croak _url_retrieval_error($response) if !$response->is_success();

    return $response->content();
}

##########################################################################
# Usage      : $error = _url_retrieval_error($response);
#
# Purpose    : Formats an error indicating that we failed to retrieve a
#              tree URL.
#
# Returns    : The formatted error.
#
# Parameters : $response - the response from the tree viewer service.
#
# Throws     : No exceptions.
sub _url_retrieval_error {
    my ($response) = @_;
    my $reason     = $response->content();
    my $msg        = "unable to retrieve tree URL: $reason";
    return _error( $response->code(), $response->content() );
}

##########################################################################
# Usage      : $value = _get_required_param( $req, $name );
#
# Purpose    : Gets the vaue of a required parameter.
#
# Returns    : the parameter value.
#
# Parameters : $req  - the request object.
#              $name - the parameter name.
#
# Throws     : Exceptions in the form of a hash.
sub _get_required_param {
    my ( $req, $name ) = @_;
    my $value = $req->param($name);
    croak _bad_request("missing required parameter: $name")
        if !defined $value;
    return $value;
}

##########################################################################
# Usage      : $error = _bad_request($msg);
#
# Purpose    : Formats a bad request error.
#
# Returns    : The error.
#
# Parameters : $msg - the error message.
#
# Throws     : No exceptions.
sub _bad_request {
    my ($msg) = @_;
    return _error( Apache2::Const::HTTP_BAD_REQUEST, $msg );
}

##########################################################################
# Usage      : $error = _error( $status, $msg, $detail );
#
# Purpose    : Formats an error.
#
# Returns    : The error.
#
# Parameters : $status - the status code to include in the error.
#              $msg    - the message to include in the error.
#              $detail - the detail information to include in the error.
#
# Throws     : No exceptions.
sub _error {
    my ( $status, $msg, $detail ) = @_;
    return { 'status' => $status, 'message' => $msg, 'detail' => $detail };
}

##########################################################################
# Usage      : $contents = _get_contents( $user, $path );
#
# Purpose    : Obtains the contents of the file at the given path.
#
# Returns    : The file contents.
#
# Parameters : $user - the username.
#              $path - the path to the file.
#
# Throws     : An error in the form of a hash.
sub _get_contents {
    my ( $user, $path ) = @_;

    # Send the request and get the response.
    my $user_agent = LWP::UserAgent->new();
    my $address    = _scruffian_address( '/download', $user, $path );
    my $response   = $user_agent->get($address);
    croak _file_retrieval_error($response) if !$response->is_success();

    return $response->content();
}

##########################################################################
# Usage      : $path = _service_address( $base, $relative, $user, $path );
#
# Purpose    : Builds a complete URL for a back-end service.
#
# Returns    : The URL.
#
# Parameters : $base     - the base URL for the service.
#              $relative - the relative path to the service.
#              $user     - the username.
#              $path     - the path to the file or directory.
#
# Throws     : No exceptions.
sub _service_address {
    my ( $base, $relative, $user, $path ) = @_;
    for my $value ( $user, $path ) {
        $value = uri_escape($value);
    }
    return "$base$relative?user=$user&path=$path";
}

##########################################################################
# Usage      : $path = _nibblonian_address( $relative, $user, $path );
#
# Purpose    : Builds a complete URL for a Nibblonian service.
#
# Returns    : The URL.
#
# Parameters : $relative - the relative path to the service.
#              $user     - the username.
#              $path     - the path to the file or directory.
#
# Throws     : No exceptions.
sub _nibblonian_address {
    return _service_address( $config{'nibblonian-prefix'}, @_ );
}

##########################################################################
# Usage      : $path = _scruffian_address( $relative, $user, $path );
#
# Purpose    : Builds a complete URL for a Scruffian service.
#
# Returns    : The URL.
#
# Parameters : $relative - the relative path to the service.
#              $user     - the username.
#              $path     - the path to the file or directory.
#
# Throws     : No exceptions.
sub _scruffian_address {
    return _service_address( $config{'scruffian-prefix'}, @_ );
}

##########################################################################
# Usage      : $error = _file_retrieval_error($response);
#
# Purpose    : Formats an error indicating that we failed to obtain the
#              file contents.
#
# Returns    : The error.
#
# Parameters : $response - the response from the file download service.
#
# Throws     : No exceptions.
sub _file_retrieval_error {
    my ($response) = @_;
    my $msg = 'unable to retrieve file contents';
    return _nibblonian_error( $msg, $response );
}

##########################################################################
# Usage      : $error = _metadata_update_error($response);
#
# Purpose    : Formats an error indicating that we failed to update the
#              file metadata.
#
# Returns    : The error.
#
# Parameters : $reponse - the response from the file download service.
#
# Throws     : No exceptions.
sub _metadata_update_error {
    my ($response) = @_;
    my $msg = 'unable to update the file metadata';
    return _nibblonian_error( $msg, $response );
}

##########################################################################
# Usage      : $error = _nibblonian_error( $msg, $response );
#
# Purpose    : Formats a general error indicating that a problem was
#              encountered while communicating with a Nibblonian service.
#
# Returns    : The error.
#
# Parameters : $msg      - the detail message to include in the error.
#              $response - the response from the service.
#
# Throws     : No exceptions.
sub _nibblonian_error {
    my ( $msg, $response ) = @_;
    my $content = $response->content();
    my $scalar = eval { _scalar_from_json($content) };
    return _error( $response->code(), "$msg: $content" )
        if !defined $scalar || !defined $scalar->{reason};
    return _error( $response->code(), "$msg: $scalar->{reason}" );
}

##########################################################################
# Usage      : @trees = _get_trees_in($contents);
#
# Purpose    : Gets the trees in the file with the given contents.
#
# Returns    : The list of trees along with their names.
#
# Parameters : $contents - the file contents.
#
# Throws     : An error in the form of a hash.
sub _get_trees_in {
    my ($contents) = @_;
    my %error_for;
    my $accepted_formats_ref = $config{'accepted-formats'};
    for my $format ( @{$accepted_formats_ref} ) {
        my $trees_ref = eval { _parse_file( $format, $contents ) };
        return @{$trees_ref} if defined $trees_ref;
        $error_for{$format} = $EVAL_ERROR;
    }
    croak _file_parse_failure( \%error_for );
}

##########################################################################
# Usage      : $error = _file_parse_failure($details_ref);
#
# Purpose    : Formats an error message for a failed attempt to parse a
#              file.  The error message details should be included in the
#              given details message.
#
# Returns    : The error.
#
# Parameters : $details_ref - a hash containing the error for each format.
#
# Throws     : No exceptions.
sub _file_parse_failure {
    my ($details_ref) = @_;
    my $msg = 'unable to extract trees from the file';
    return _error( Apache2::Const::HTTP_BAD_REQUEST, $msg, $details_ref );
}

##########################################################################
# Usage      : $trees_ref = _parse_file( $format, $contents );
#
# Purpose    : Parses the file with the given contents assuming that the
#              file is in the given format and returns a reference to the
#              list of trees in the file.  If an error occurs during
#              parsing or no trees are found in the file then an exception
#              is thrown.
#
# Returns    : A reference to the list of trees in the file.
#
# Parameters : $format   - the assumed file format.
#              $contents - the file contents.
#
# Throws     : "NCL successfully parsed the file, but no trees were found"
#              Any exception thrown by the tree parser.
sub _parse_file {
    my ( $format, $contents ) = @_;
    my $parser = IPlant::Buggalo::TreeParser->new($format);
    $parser->parse($contents);
    my @trees = $parser->get_trees();
    croak 'NCL successfully parsed the file, but no trees were found'
        if scalar @trees == 0;
    return \@trees;
}

# Variables required for linking.
my $INSTALL_PREFIX;
my $LDDLFLAGS;
my $LIB_PATH;

# Set up the environment for loading NCL.
BEGIN {
    my $INSTALL_PREFIX_VAR = 'IPLANT_BUGGALO_PREFIX';
    $INSTALL_PREFIX
        = defined $ENV{$INSTALL_PREFIX_VAR}
        ? $ENV{$INSTALL_PREFIX_VAR}
        : q{};
    $LIB_PATH  = '/usr/local/lib/ncl';
    $LDDLFLAGS = "$Config{lddlflags} -Wl,-rpath $LIB_PATH";
}

# The interface to the Nexus Class Library is implemented in C++.
use Inline 'Config',
    'DIRECTORY' => "$INSTALL_PREFIX/usr/local/apache/Inline",
    'ENABLE'    => 'UNTAINT';
use Inline
    'CPP'       => 'Config',
    'LIBS'      => "-L$LIB_PATH -lncl",
    'LDDLFLAGS' => $LDDLFLAGS;
use Inline 'CPP' => <<'END_OF_CPP_CODE';

#include <iostream>
#include <sstream>
#include <string>
#include <exception>
#include <vector>

#include "ncl/nxsmultiformat.h"
#include "ncl/nxstreesblock.h"
#include "ncl/nxsexception.h"

/**
 * Represents general tree information.
 */
class TreeInfo {
public:
    TreeInfo(std::string name, std::string newick);

    SV *to_av_ref();

private:
    std::string name;
    std::string newick;
};

/**
 * Represents a tree parser.
 */
class TreeParser {
public:
    TreeParser(char *format);
    ~TreeParser();

    void parse(SV *contents_sv);
    void get_trees();

private:
    MultiFormatReader reader;
    char *format;
    std::vector<TreeInfo> *trees;
    NxsTaxaBlock *current_taxa_block;
    TreesBlock *current_trees_block;

    void load_all_trees();
    void load_trees_in_taxa_block();
    void load_trees_in_trees_block();
};

/**
 * Creates a new tree information object with the given tree name and Newick
 * string.
 *
 * parameters:
 *   name   - the name of the tree.
 *   newick - the Newick string representing the tree.
 */
TreeInfo::TreeInfo(std::string name, std::string newick) {
    this->name = name;
    this->newick = newick;
}

/**
 * Creates an AV (Perl array value) reference for the tree information object.
 *
 * returns:
 *   A reference to a Perl array containing the tree name and Newick string.
 */
SV *TreeInfo::to_av_ref() {
    AV *av = newAV();
    av_push(av, newSVpvn(name.c_str(), name.length()));
    av_push(av, newSVpvn(newick.c_str(), newick.length()));
    return newRV_noinc((SV *) av);
}

/**
 * Creates a new tree parser that works with the given file format.
 *
 * parameters:
 *   format - the file format recognized by the new tree parser.
 */
TreeParser::TreeParser(char *format): reader(-1) {
    this->format = savepv(format);

    // Tell the reader not to throw an exception unless a fatal error occurs.
    reader.SetWarningToErrorThreshold(NxsReader::FATAL_WARNING);

    // Tell the reader to allow augmented sequence symbols.
    NxsCharactersBlock *chars_block = reader.GetCharactersBlockTemplate();
    NxsDataBlock *data_block = reader.GetDataBlockTemplate();
    chars_block->SetAllowAugmentingOfSequenceSymbols(true);
    data_block->SetAllowAugmentingOfSequenceSymbols(true);

    // Allow implicit names in trees blocks.
    NxsTreesBlock *trees_block = reader.GetTreesBlockTemplate();
    trees_block->SetAllowImplicitNames(true);

    // Allow unterminated blocks.
    NxsStoreTokensBlockReader *storer_block = reader.GetUnknownBlockTemplate();
    storer_block->SetTolerateEOFInBlock(true);
}

/**
 * Destroys a tree parser.
 */
TreeParser::~TreeParser() {
    Safefree(format);
    reader.DeleteBlocksFromFactories();
}

/**
 * Parses a tree file.
 *
 * parameters:
 *   contents_sv - a Perl scalar value containing the file contents.
 */
void TreeParser::parse(SV *contents_sv) {
    try {
        STRLEN len;
        char *contents_cstr = SvPV(contents_sv, len);
        std::string contents(contents_cstr, len);
        std::istringstream in(contents);
        reader.ReadStream(in, format);
    }
    catch (NxsException e) {
        croak("%s\n", e.nxs_what());
    }
    catch (std::exception e) {
        croak("%s\n", e.what());
    }
    catch (...) {
        croak("unknown error occurred while parsing tree");
    }
}

/**
 * Gets the trees in the file that was most recently parsed by this object.
 *
 * Returns:
 *   Nothing, but references to arrays containing the tree names and Newwick
 *   strings are placed on the Perl stack.
 */
void TreeParser::get_trees() {
    Inline_Stack_Vars;
    Inline_Stack_Reset;
    trees = new std::vector<TreeInfo>();
    load_all_trees();
    std::vector<TreeInfo>::iterator it = trees->begin();
    int id_index;
    while (it != trees->end()) {
        Inline_Stack_Push(sv_2mortal(it->to_av_ref()));
        it++;
    }
    delete trees;
    trees = NULL;
    Inline_Stack_Done;
}

/**
 * Loads all trees into a vector.
 */
void TreeParser::load_all_trees() {
    int num_taxa_blocks = reader.GetNumTaxaBlocks();
    for (int i = 0; i < num_taxa_blocks; i++) {
        current_taxa_block = reader.GetTaxaBlock(i);
        load_trees_in_taxa_block();
    }
    current_taxa_block = NULL;
}

/**
 * Loads all trees in the current taxa block into a vector.
 */
void TreeParser::load_trees_in_taxa_block() {
    int num_trees_blocks = reader.GetNumTreesBlocks(current_taxa_block);
    for (int i = 0; i < num_trees_blocks; i++) {
        current_trees_block = reader.GetTreesBlock(current_taxa_block, i);
        load_trees_in_trees_block();
    }
    current_trees_block = NULL;
}

/**
 * Loads all trees in the current trees block into a vector.
 */
void TreeParser::load_trees_in_trees_block() {
    int num_trees = current_trees_block->GetNumTrees();
    for (int i = 0; i < num_trees; i++) {
        NxsFullTreeDescription desc = current_trees_block->GetFullTreeDescription(i);
        NxsSimpleTree tree(desc, 1, 1.0);
        std::ostringstream out;
        tree.WriteAsNewick(out, false, true, true, current_taxa_block);
        TreeInfo info(desc.GetName(), out.str());
        trees->push_back(info);
    }
}

END_OF_CPP_CODE

1;
__END__

=for stopwords iPlant Nibblonian iRODS JSON metadata modperl NibblonianPrefix
TreeParserUrl AcceptedTreeFormats CPAN libapreq2 libwww-perl Readonly Inline

=head1 NAME

IPlant::Buggalo - mod_perl handler for a tree viewer extraction service.

=head1 VERSION

This documentation refers to IPlant::Buggalo Version 0.4.1

=head1 SYNOPSIS

    # Basic configuration.
    <Location /mulcher>
        SetHandler modperl
        PerlResponseHandler IPlant::Buggalo
        PerlSetVar zookeeper "by-tor:1234,snow-dog:4321"
    </Location>

    # Calling the service using curl.
    curl 'http://hostname/mulcher?user=username&path=/path/to/irods/file'
    curl -d @/path/to/tree/file http://hostname/mulcher

=head1 DESCRIPTION

The primary purpose of this module is to integrate the iPlant Discovery
Environment (DE) with the tree parser service in order to enable tree
visualization in the DE.  If a user chooses to open a file with the tree
viewer the DE first checks to see if it received any tree URLs from the file
management service (Nibblonian).  If no tree URLs were received, the DE calls
this service in order to attempt to retrieve tree URLs.

For HTTP GET requests, this service accepts two parameters in the query
string: the name of the user who is viewing the file and the absolute path to
the file in iRODS.  Both parameters are required, and a 400 error will be
returned if either is missing.

When a GET request is received, this service first contacts Scruffian to
retrieve the contents of the file.  Once the file contents have been
retrieved, the contents are passed to the Nexus Class Library for parsing.
Each tree in the file is then sent to the tree parsing service, which returns
a URL that can be used to view the tree.  These URLs are collected and
returned to the caller as a JSON document in the following format:

    {   "tree-urls" : [
            {   "url" : "http://hostname/view/1",
                "label" : "tree0"
            },
            ...
        ]
    }

The collected URLs are also associated with the file using the tree-urls
endpoint in Nibblonian so that it will not be necessary to call the mulcher
service to view trees for the same file in the future.

For HTTP POST requests, no query string parameters are required.  Instead, the
request body is passed to the Nexus Class Library for parsing and each tree in
the file is passed to the tree viewer service for processing.  There is no
interaction with Scruffian or Nibblonian in this case, so it is not necessary
for the file to be stored in iRODS and the tree URLs will not be associated
with the file if it is stored in iRODS.  The primary purpose of the POST
service is to make debugging easier; with the POST service a tester or
developer can post the file contents directly to the mulcher in order to
obtain useful information about why a specific file is not successfully being
processed.

When an error occurs, this handler attempts to trap the error and create a
JSON response that provides information about the error.  For example, failing
to provide a required parameter will result in a message that looks something
like this:

    {   "message" : "missing required parameter: path",
        "status"  : "error"
    }

In some cases (for example, failure to parse a file using any of the acceptable
formats), more detailed information is necessary.  In these cases, you may see
an error message that looks something like this:

    {   "detail" : {
            "rnaaln" : "Nexus Parsing error: <details>",
            "relaxedphyliptree" : "Nexus Parsing error: <details>",
            "nexus" : "Nexus Parsing error: <details>",
            "aaaln" : "Nexus Parsing error: <details>"
        },
        "status" : "error",
        "message" : "unable to extract trees from the file"
    }

The only exceptions to this rule are configuration errors, which are not
trapped so that the error text will show up in Apache's log files.  This means
that the user will get Apache's standard error response if the service is
configured incorrectly.

=head1 SUBROUTINES/METHODS

=head2 handler

This subroutine handles incoming HTTP requests, and it is the only public
subroutine in this module.  See the DESCRIPTION section of this document
for information about the behavior of this subroutine.

=head1 DIAGNOSTICS

=head2 CONFIGURATION ERROR: missing zookeeper perl var

The perl variable used to tell the module how to connect to Zookeeper was not
provided in the loation configuration in the Apache configuration file.
Verify that the Apache configuration file is correct.

=head2 CONFIGURATION ERROR: services are not allowed on this host

Zookeeper has no ACL information for the local host.  Verify that the
Zookeeper connection string in the Apache configuration file is correct and
that the ACLs that have been loaded into Zookeeper using Clavin are correct.

=head2 INTERNAL ERROR: unrecognized configuration type

One of the configuration types used when loading the configuration settings
from the Apache configuration file wasn't recognized.  This error indicates
that there's a bug in this module.

=head2 CONFIGURATION ERROR: missing <name> configuration parameter

The configuration parameter with the given name was not specified in the Apache
configuration file.  Check the service configuration for spelling and
completeness.

=head2 unable to update the file metadata

The response to the tree URL update request from Nibblonian indicated that an
error occurred.  Review the Nibblonian error logs for more information about
the cause of the error.

=head2 unable to retrieve tree URL: <reason>

The response to the tree URL retrieval request from the tree parser service
indicated that an error occurred.  Review the stated reason and the tree
parser service error logs for more information about the cause of the error.

=head2 missing required parameter: <name>

The query string parameter with the given name wasn't included in the request.
Check the request URL for spelling and completeness.

=head2 unable to retrieve file contents: <reason>

The response to the file contents retrieval request from Scruffian indicated
that an error occurred.  Review the stated reason and the Scruffian error logs
for more information about the cause of the error.

=head2 unable to extract trees from the file

The Nexus Class Library rejected the file for each of the formats that the
service tried.  When this occurs, the "details" element of the response body
will contain the name of each format that the service tried along with a
message indicating why parsing failed for that format.  Verify that the
selected tree file is formatted correctly and that it is in one of the formats
supported by this service.  Note that additional formats that are already
supported by the Nexus Class Library but are not currently supported by this
service can be added by modifying the Apache configuration file.

=head2 Other Errors

Any other errors produced by this service are unintentional and indicate that
there is a bug in this module.

=head1 CONFIGURATION AND ENVIRONMENT

This module requires the presence of a directory to compile the C++ glue code
that is required to interface to the Nexus Class Library.  This directory is
C</usr/local/apache/Inline>.  This directory must be present and writable by
the account used to run Apache before this module can be used.

This module is designed to be used as a mod_perl response handler, so this
section will focus on ways to configure a service that uses this handler.
A simple service configuration looks something like this:

    <Location /mulcher>
        SetHandler modperl
        PerlResponseHandler IPlant::Buggalo
        PerlSetVar zookeeper "by-tor:1234,snow-dog:4321"
    </Location>

The handler should always be set to "modperl" and the response handler should
be set to the name of this module.  This module currently has one
configuration parameter that must be included in the location definition:
C<zookeeper>.  This configuration setting contains the Zookeeper connection
settings.  There are also several different configuraiton settings that must
be loaded into Zookeeper using Clavin: C<buggalo.nibblonian-prefix>,
C<buggalo.scruffian-prefix>, C<buggalo.tree-parser-url> and
C<buggalo.accepted-tree-formats>.  The properties that are loaded into
Zookeeper by Clavin should have the name C<buggalo.properties>, and should
look something like this:

    # The base URLs to use when contacting various services.
    buggalo.nibblonian-prefix = http://by-tor:8888
    buggalo.scruffian-prefix  = http://by-tor:9999
    buggalo.tree-parser-url   = http://snow-dog/parseTree

    # The tree formats that the service can accept.
    buggalo.accepted-tree-formats = nexml, rnaaln, aaaln

Because of limitations inherent in the way that this module handles
configuration settings, only one service may be configured to use this module
on any given server.

=head2 zookeeper

This configuration setting is specified in the location definition for the
service using C<PerlSetVar> as described above.  The value of this
configuraiton setting should be a standard Zookeeper connection string in the
format C<host1:port1,host2:port2,...,hostn:portn>.  For example, the
connection string could be something like this:

    by-tor:1234,snow-dog:4321

This would indicate that Zookeeper can be contacted by connecting to by-tor on
port 1234 or by connecting to snow-dog on port 4321.

=head2 buggalo.nibblonian-prefix

This configuration setting is specified in the properties that are stored in
Zookeeper and contains the URL prefix to use when contacting Nibblonian
services.  This should be specified up to and including the context name.  For
example, if the host name is C<by-tor.iplantc.org> and the context name is
C<nibblonian> then the value of this configuration setting would be

    http://by-tor.iplantc.org/nibblonian

Similarly, if the host name is C<snow-dog.iplantc.org>, the port is C<14444>
and the context name is nibblonian_123 then the value of this configuration
parameter would be

    http://snow-dog.iplantc.org:14444/nibblonian_123

Note that this configuration parameter must point to the same Nibblonian
instance that is used by the DE.  A service mismatch will cause apparently
incorrect C<file not found> messages.

=head2 buggalo.scruffian-prefix

This configuration setting is specified in the properties that are stored in
Zookeeper and contains the URL prefix to use when contacting Scruffian
services.  This should be specified up to and including the context name if
there is one.  For example, if the host name is C<by-tor.iplantc.org> and the
context name is C<scruffian> then the value of this configuration setting
would be

    http://by-tor.iplantc.org/scruffian

Similarly, if the host name is C<snow-dog.iplantc.org>, the port is C<14444>
and the context name is scruffian_123 then the value of this configuration
parameter would be

    http://snow-dog.iplantc.org:14444/scruffian_123

Note that this configuration parameter must point to the same Scruffian
instance that is used by the DE.  A service mismatch will cause the apparently
incorrect C<file not found> messages.

=head2 TreeParserUrl

This configuration setting is specified in the properties that are stored in
Zookeeper and contains the URL to use when contacting the tree parser service.
The value of this setting should be the full tree parser service URL.  The URL
will generally be in the following format:

    http://hostname.iplantcollaborative.org/parseTree

=head2 AcceptedTreeFormats

This configuration setting is specified in the properties that are stored in
Zookeeper and contains the list of formats that are accepted by this service.
The value of this setting should be a comma-delimited list containing the
names of the accepted tree formats.  Whitespace may optionally be included
after each comma in the string. For exmaple, if the formats,
C<relaxedphyliptree>, C<discretephyliptree> and C<nexus>, are all supported
then the value of this configuration setting should be something like this:

    relaxedphyliptree, discretephyliptree, nexus

The set of formats accepted by this configuration parameter is the same as the
set of formats supported by the Nexus Class Library.  At the time of this
writing the supported formats are:

    nexus
    dnafasta
    aafasta
    rnafasta
    dnaphylip
    rnaphylip
    aaphylip
    discretephylip
    dnaphylipinterleaved
    rnaphylipinterleaved
    aaphylipinterleaved
    discretephylipinterleaved
    dnarelaxedphylip
    rnarelaxedphylip
    aarelaxedphylip
    discreterelaxedphylip
    dnarelaxedphylipinterleaved
    rnarelaxedphylipinterleaved
    aarelaxedphylipinterleaved
    discreterelaxedphylipinterleaved
    dnaaln
    rnaaln
    aaaln
    phyliptree
    relaxedphyliptree
    nexml

See the documentation for the Nexus Class Library for more information.

=head1 DEPENDENCIES

=head2 Apache2::Const 2.000004

This module is included with mod_perl version 2.0.4, which is available from
CPAN.

=head2 Apache2::Request 2.12

This module is included with libapreq2 version 2.12, which is available from
CPAN.

=head2 Apache2::Response 2.000004

This module is included with mod_perl version 2.0.4, which is available from
CPAN.

=head2 Apache2::RequestRec 2.000004

This module is included with mod_perl version 2.0.4, which is available from
CPAN.

=head2 Apache2::RequestIO 2.000004

This module is included with mod_perl version 2.0.4, which is available from
CPAN.

=head2 Carp

This module is included with Perl.

=head2 English

This module is included with Perl.

=head2 File::Basename

This module is included with Perl.

=head2 HTTP::Request::Common 5.811

This module is included with HTTP::Message, which is available from CPAN.

=head2 JSON 2.22

This module is available from CPAN.

=head2 LWP::UserAgent 5.813

This module is included with libwww-perl, which is available from CPAN.

=head2 Readonly 1.03

This module is available from CPAN.

=head2 URI::Escape 3.29

This module is included with URI, which is available from CPAN.

=head2 IPlant::Clavin 0.1.0

This module is available from iPlant's local CPAN repository.

=head2 Inline::CPP 0.25

This module is available from CPAN.

=head2 Inline 0.48

This module is available from CPAN.

=head2 Nexus Class Library 2.1.18

This is a C++ library that can be obtained from
http://sourceforge.net/projects/ncl.

=head1 INCOMPATIBILITIES

This module has no known incompatibilities.

=head1 BUGS AND LIMITATIONS

Because of limitations in the way that this module is configured, this module
may only be used to handle at most one service in any given Apache server.

The library that is being used to parse trees (the Nexus Class Library) is a
lot more restrictive than the in-house parser that was used in previous
versions of the Discovery Environment.  This may cause files that were
successfully parsed by older versions of the Discovery Environment not to be
parsed.

There are no other known bugs or limitations.  Please report problems to the
iPlant Collaborative.  Patches are welcome.

=head1 AUTHOR

Dennis Roberts, C<< <dennis at iplantcollaborative.org> >>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2011, The Arizona Board of Regents on behalf of The University
of Arizona

All rights reserved.

Developed by: iPlant Collaborative at BIO5 at The University of Arizona
http://www.iplantcollaborative.org

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

 * Neither the name of the iPlant Collaborative, BIO5, The University of
   Arizona nor the names of its contributors may be used to endorse or promote
   products derived from this software without specific prior written
   permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
