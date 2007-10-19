package POE::Component::Server::JSONRPC;
use strict;
use warnings;
use base qw/Class::Accessor::Fast/;

our $VERSION = '0.01';

use POE qw/
    Component::Server::TCP
    Filter::Line
    /;
use JSON::Any;

=head1 NAME

POE::Component::Server::JSONRPC - POE tcp based JSON-RPC server

=head1 SYNOPSIS

    POE::Component::Server::JSONRPC->new(
        Port    => 3000,
        Handler => {
            'echo' => 'echo',
            'sum'  => 'sum',
        },
    );
    
    sub echo {
        my ($kernel, $jsonrpc, @params) = @_[KERNEL, ARG0..$#_ ];
    
        $kernel->post( $jsonrpc => 'result' => @params );
    }
    
    sub sum {
        my ($kernel, $jsonrpc, @params) = @_[KERNEL, ARG0..$#_ ];
    
        $kernel->post( $jsonrpc => 'result' => $params[0] + $params[1] );
    }

=head1 DESCRIPTION

This module is a POE component for tcp based JSON-RPC Server.

The specification is defined on http://json-rpc.org/ and this module use JSON-RPC 1.0 spec (1.1 does not cover tcp streams)

=head1 METHODS

=head2 new

Create JSONRPC component session and return the session id.

Parameters:

=over

=item Port

Port number for listen.

=item Handler

Hash variable contains handler name as key, handler poe state name as value.

Handler name (key) is used as JSON-RPC method name.

So if you send {"method":"echo"}, this module call the poe state named "echo".

=back

=cut

sub new {
    my $self = shift->SUPER::new( @_ > 1 ? {@_} : $_[0] );

    $self->{parent} = $poe_kernel->get_active_session->ID;
    $self->{json} ||= JSON::Any->new;

    my $session = POE::Session->create(
        object_states => [
            $self => {
                map { ( $_ => "poe_$_", ) }
                    qw/_start tcp_input_handler result error/
            },
        ],
    );

    $session->ID;
}

=head1 HANDLER PARAMETERS

=over

=item ARG0

A session id of PoCo::Server::JSONRPC itself.

=item ARG1 .. ARGN

JSONRPC argguments

=back

ex) If you send following request

    {"method":"echo", "params":["foo", "bar"]}

then, "echo" handler is called and parameters is that ARG0 is component session id, ARG1 "foo", ARG2 "bar".

=head1 HANDLER RESPONSE

You must call either "result" or "error" state in your handlers to response result or error.

ex:

   $kernel->post( $component_session_id => "result" => "result value" )

$component_session_id is ARG0 in handler. If you do above, response is:

   {"result":"result value", "error":""}


=head1 POE METHODS

Inner method for POE states.

=head2 poe__start

=cut

sub poe__start {
    my ($self, $kernel, $session) = @_[OBJECT, KERNEL, SESSION];

    my $bind = sub {
        my $method = $_[0];

        return sub {
            my ($kernel, $tcp_session, @args) = @_[KERNEL, SESSION, ARG0..$#_ ];
            $kernel->post( $session->ID, $method, $tcp_session->ID, @args );
        };
    };

    $self->{tcp} = POE::Component::Server::TCP->new(
        Port => $self->{Port},
        $self->{Address}     ? ( Address     => $self->{Address} )     : (),
        $self->{Hostname}    ? ( Hostname    => $self->{Hostname} )    : (),
        $self->{Domain}      ? ( Domain      => $self->{Domain} )      : (),
        $self->{Concurrency} ? ( Concurrency => $self->{Concurrency} ) : (),

        ClientInput        => $bind->('tcp_input_handler'),
#        ClientConnected    => $bind->('tcp_connect_handler'),
#        ClientDisconnected => $bind->('tcp_disconnect_handler'),
#        ClientError        => $bind->('tcp_client_error_handler'),
#        ClientFlushed      => $bind->('tcp_client_flush_handler'),

        ClientInputFilter => $self->{ClientInputFilter} || POE::Filter::Line->new,
        ClientOutputFilter => $self->{ClientOutputFilter} || POE::Filter::Line->new,

        InlineStates => {
            send => sub {
                my ($heap, $data) = @_[HEAP, ARG0];
                $heap->{client}->put($data) if $heap->{client};
            },
        },
    );
}

=head2 poe_tcp_input_handler

=cut

sub poe_tcp_input_handler {
    my ($self, $kernel, $session, $heap, $client, @args) = @_[OBJECT, KERNEL, SESSION, HEAP, ARG0..$#_ ];
    $heap->{client} = $client;

    my $json;
    eval {
        $json = $self->{json}->Load( $args[0] );
    };
    if ($@) {
        $kernel->yield('error', q{invalid json request});
        return;
    }

    unless ($json and $json->{method}) {
        $kernel->yield('error', q{parameter "method" is required});
        return;
    }

    unless ($self->{Handler}{ $json->{method} }) {
        $kernel->yield('error', qq{no such method "$json->{method}"});
        return;
    }

    $heap->{id} = $json->{id};
    my $handler = $self->{Handler}{ $json->{method} };
    my @params = @{ $json->{params} || [] };

    $kernel->post( $self->{parent}, $handler, $session->ID, @params );
}

=head2 poe_result

=cut

sub poe_result {
    my ($self, $kernel, $heap, @results) = @_[OBJECT, KERNEL, HEAP, ARG0..$#_ ];

    $kernel->post(
        $heap->{client} => send => $self->{json}->Dump(
            {   id => $heap->{id} || undef,
                error  => undef,
                result => (@results > 1 ? \@results : $results[0]),
            }
        ),
    );
}

=head2 poe_error

=cut

sub poe_error {
    my ($self, $kernel, $heap, $error) = @_[OBJECT, KERNEL, HEAP, ARG0];

    $kernel->post(
        $heap->{client} => send => $self->{json}->Dump(
            {   id => $heap->{id} || undef,
                error  => $error,
                result => undef,
            }
        ),
    );

}


=head1 AUTHOR

Daisuke Murase <typester@cpan.org>

=head1 COPYRIGHT

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=cut

1;
