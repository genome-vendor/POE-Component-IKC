package POE::Component::IKC::Responder;

############################################################
# $Id$
# Based on tests/refserver.perl
# Contributed by Artur Bergman <artur@vogon-solutions.com>
# Revised for 0.06 by Rocco Caputo <troc@netrus.net>
# Turned into a module by Philp Gwyn <fil@pied.nu>
#
# Copyright 1999 Philip Gwyn.  All rights reserved.
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# Contributed portions of IKC may be copyright by their respective
# contributors.  

use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $ikc);
use Carp;
use Data::Dumper;

use POE qw(Session);
use POE::Component::IKC::Specifier;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(create_ikc_responder $ikc);
$VERSION = '0.09';

sub DEBUG { 0 }

##############################################################################

#----------------------------------------------------
# This is just a convenient way to create only one responder.
sub create_ikc_responder 
{
    return if $ikc;
    new POE::Session( __PACKAGE__ , [qw(
                      _start _stop
                      request post call raw_message
                      remote_error
                      register unregister default  
                      publish retract subscribe unsubscribe
                      do_you_have ping
                    )]);
}

#----------------------------------------------------
# Accept POE's standard _start message, and start the responder.
sub _start
{
    my($kernel, $heap, $session) = @_[KERNEL, HEAP, SESSION];
    DEBUG && print "Responder started.\n";
    $kernel->alias_set('IKC');              # allow it to be called by name

    $ikc=POE::Component::IKC::Responder::Object->new($kernel, $session);
    $heap->{self}=$ikc;
}


sub _stop
{
#    warn "$_[HEAP] responder _stop\n";
}

#----------------------------------------------------
# Foreign kernel called something here
sub request
{
    my($kernel, $heap, $request) = @_[KERNEL, HEAP, ARG0];
    $heap->{self}->request($request);
}

#----------------------------------------------------
# Register foreign kernels so that we can send states to them
sub register
{
    my($heap, $channel, $names) = @_[HEAP, SENDER, ARG0];
    $names=[$names] if not ref $names;
    $heap->{self}->register($channel, @$names);
}

#----------------------------------------------------
# Unregister foreign kernels when this disconnect (say)
sub unregister
{
    my($kernel, $heap, $channel, $names) = @_[KERNEL, HEAP, SENDER, ARG0];
    $names=[$names] if not ref $names;
    $heap->{self}->unregister($channel, @$names);
}
#----------------------------------------------------
# Set a default foreign channel to send messages to
sub default
{
    my($heap, $name) = @_[HEAP, ARG0];
    $heap->{self}->default($name);
}


##############################################################################
## These are the 4 states that interact with the foreign kernel

#----------------------------------------------------
# Send a request to the foreign kernel
sub post
{
    my($heap, $to, $params, $sender) = @_[HEAP, ARG0, ARG1, SENDER];
    $heap->{self}->post($to, $params, $sender);
}

#----------------------------------------------------
# Send a request to the foreign kernel and ask it to provide 
# the state's return value back
sub call
{
    my($kernel, $heap, $sender, $to, $params, $rsvp) = 
                    @_[KERNEL, HEAP, SENDER, ARG0, ARG1, ARG2];

    $heap->{self}->call($to, $params, $rsvp, $sender);
    return;
}

#----------------------------------------------------
# Send a raw message over.  use at your own risk :)
# This is useful for sending errors to remote ClientLite
sub raw_message
{
    my($heap, $msg, $sender) = @_[HEAP, ARG0, ARG1];
    $heap->{self}->send_msg($msg, $sender);
}

#----------------------------------------------------
# Remote kernel had an error 
sub remote_error
{
    my($heap, $msg) = @_[HEAP, ARG0];

    warn "Remote error: $msg\n";
}

##############################################################################
# publish/retract/subscribe mechanism of setting up foreign sessions

#----------------------------------------------------
sub publish
{
    my($kernel, $heap, $sender, $session, $states)=
      @_[KERNEL, HEAP, SENDER,  ARG0,     ARG1];
    $session||=$sender;
    $heap->{self}->publish($session, $states);
}

#----------------------------------------------------
sub retract
{
    my($heap, $sender, $states, $session)=
        @_[HEAP, SENDER, ARG0, ARG1];

    $session||=$sender;
    $heap->{self}->retract($session, $states);
}


#----------------------------------------------------
sub subscribe
{
    my($kernel, $heap, $sender, $sessions, $callback)=
                @_[KERNEL, HEAP, SENDER, ARG0, ARG1];
    $sessions=[$sessions] unless ref $sessions;
    return unless @$sessions;

    if($callback)
    {
        my $state=$callback;
        $callback=sub 
        {
            DEBUG && print "Subscription callback to '$state'\n";
            $kernel->post($sender, $state, @_);
        };
    }
    $heap->{self}->subscribe($sessions, $callback, $sender->ID);
}

# Called by a foreign IKC session 
# We respond with the session, or with "NOT $specifier";
sub do_you_have
{
    my($kernel, $heap, $param)=@_[KERNEL, HEAP, ARG0];
    my $ses=specifier_parse($param->[0]);
    die "Bad state $param->[0]\n" unless $ses;

    my $self=$heap->{self};
    
    DEBUG && print "Wants to subscribe to ", specifier_name($ses), "\n";
    if(exists $self->{'local'}{$ses->{session}} and
       (not $ses->{state} or 
        exists $self->{'local'}{$ses->{session}}{$ses->{state}}
       ))
    {
        $ses->{kernel}||=$kernel->ID;       # make sure we uniquely identify 
        DEBUG && print "Allowed (we are $ses->{kernel})\n";
        return $ses;                        # this session
    } else
    {
        DEBUG && print specifier_name($ses), " is not published in this kernel\n";
        return "NOT ".specifier_name($ses);
    }
}

#----------------------------------------------------
sub unsubscribe
{
    my($kernel, $heap, $states)=@_[KERNEL, HEAP, ARG0];
    $states=[$states] unless ref $states;
    return unless @$states;
    croak "Not done";
    $heap->{self}->unsubscribe($states);
}


#----------------------------------------------------
sub ping
{
    "PONG";
}



##############################################################################



##############################################################################
# Here is the object interface
package POE::Component::IKC::Responder::Object;
use strict;

use Carp;
use POE::Component::IKC::Specifier;
use POE::Component::IKC::Proxy;
use POE qw(Session);

use Data::Dumper;

sub DEBUG { 0 }
sub DEBUG2 { 0 }

sub new
{
    my($package, $kernel, $session)=@_;
    my $self=bless 
        {
            'local'=>{IKC=>{remote_error=>1, # these states are auto-published
                            do_you_have=>1,
                            ping=>1,
                           },
                     },
            remote=>{},
            rsvp=>{},
            kernel=>{},
            channel=>{},
            default=>{},
            poe_kernel=>$kernel,
            myself=>$session,
        }, $package;
}

#----------------------------------------------------
# Foreign kernel called something here
sub request    
{
    my($self, $request)=@_;;
    my($kernel)=@{$self}{qw(poe_kernel)};
    # DEBUG2 && print Dumper $request;

    # We ignore the kernel for now, but we should really use it to decide
    # weither we should run the request or not
    my $to=specifier_parse($request->{event});
    eval
    {
        die "$request->{event} isn't a valid specifier" unless $to;
        my $args=$request->{params};
        # allow proxied states to have multiple ARGs
        if($to->{state} eq 'IKC:proxy')   
        {
            $to->{state}=$args->[0];
            $args=$args->[1];
            DEBUG && print "IKC proxied request for ", specifier_name($to), "\n";
        } else
        {
            DEBUG && print "IKC request for ", specifier_name($to), "\n";
            $args=[$args];
        }
          
        # find out if the state we want to get at has been published
        if(exists $self->{rsvp}{$to->{session}} and
           exists $self->{rsvp}{$to->{session}}{$to->{state}} and
           $self->{rsvp}{$to->{session}}{$to->{state}}
          ) {
            $self->{rsvp}{$to->{session}}{$to->{state}}--;
            DEBUG && print "Allow $to->{session}/$to->{state} is now $self->{rsvp}{$to->{session}}{$to->{state}}\n";
        }
        elsif(not exists $self->{'local'}{$to->{session}}) {
            die "Session $to->{session} is not available for remote kernels\n";
        } 
        elsif(not exists $self->{'local'}{$to->{session}}{$to->{state}}) {
            die "Session '$to->{session}' has not published state '",
                $to->{state}, "'\n";
        }


        my $session=$kernel->alias_resolve($to->{session});
        die "Unknown session '$to->{session}'\n" unless $session;

        _thunked_post($request->{rsvp},
                      [$session, $to->{state}, @$args], $request->{from});
    };


    # Error handling consists of posting a "remote_error" state to
    # the foreign kernel.
    # $request->{errors_to} is set by the local IKC::Channel
    if($@)
    {
        chomp($@);
        my $err=$@.' ['.specifier_name($to).']';
        DEBUG && warn "Error in request: $err\n";
        unless($request->{is_error})    # don't send an error message back
        {                               # if this was an error itself
            $self->send_msg({ event=>$request->{errors_to},
                              params=>$err, is_error=>1,
                            });
        } else
        {
            warn Dumper $request;
        }
    }
}

#----------------------------------------------------
# Register foreign kernels so that we can send states to them
sub register
{
    my($self, $channel, $rid, @todo)=@_;
    
    $self->{channel}{$rid}=$channel;
    $self->{remote}{$rid}=[];
    $self->{alias}{$rid}=[@todo];

    DEBUG && print "Registered kernel '$rid' ";
    $self->{default}||=$rid;

    foreach my $name (@todo)
    {
        DEBUG && print "'$name' ";
        $self->{kernel}{$name}=$rid;
        $self->{remote}{$name}||=[];
    }

    DEBUG && print "\n";
    return 1;
}

sub default
{
    my($self, $name) = @_;
    if(exists $self->{kernel}{$name})
    {
        $self->{default}=$self->{kernel}{$name};

    } elsif(exists $self->{channel}{$name})
    {
        $self->{default}=$name;

    } else
    {
        carp "We do not know the kernel $name.\n";
        return;
    }

    DEBUG && print "Default kernel is on channel $name.\n";
}

#----------------------------------------------------
# Register foreign kernels when this disconnect (say)
sub unregister
{
    my($self, $channel, @todo)=@_;
    my($kernel)=@{$self}{qw(poe_kernel)};

    my $name;
    while(@todo)
    {
        $name=shift @todo;
        next unless defined $name;
        if($self->{channel}{$name})       # this is in fact the real name
        {
                                    # so we delete aliases too
            push @todo, @{$self->{alias}{$name}};    
            $self->{'default'}='' if $self->{'default'} eq $name;

            $kernel->post($self->{channel}{$name}, 'close');
            delete $self->{channel}{$name};
            delete $self->{alias}{$name};

            DEBUG && print "Unregistered kernel '$name'.\n";

        } elsif($self->{kernel}{$name})
        {
            DEBUG && print "Unregistered kernel alias '$name'.\n";
            delete $self->{kernel}{$name};
            $self->{'default'}='' if $self->{'default'} eq $name;
        } else
        {
            # already gone...
        }
                # tell the proxies they are no longer needed
        if($name)
        {
            foreach my $alias (@{$self->{remote}{$name}})
            {
                $self->{poe_kernel}->post($alias, '_delete');
            }
            delete $self->{remote}{$name};
        }
    }
    return 1;
}


#----------------------------------------------------
# Set a default foreign channel to send messages to



#----------------------------------------------------
# Internal function that does all the work of preparing a request to be sent
sub send_msg
{
    my($self, $msg, $sender)=@_;
    my($kernel)=@{$self}{qw(poe_kernel)};

    my $e=$msg->{rsvp} ? 'call' : 'post';

    my $to=specifier_parse($msg->{event});
    unless($to) {
        croak "Bad state ", Dumper $msg, caller;
    }
    unless($to) {
        warn "Bad or missing 'to' parameter '$msg->{event}' to poe:/IKC/$e\n";
        return;
    }
    unless($to->{session}) {
        warn "Need a session name in poe:/IKC/$e";
        return;
    }
    unless($to->{state})   {
        carp "Need an state name in poe:IKC/$e";
        return;
    }

    my $name=$to->{kernel}||$self->{'default'};
    unless($name) {
        warn "Unable to decide which kernel to send state '$to->{state}' to.";
        return;
    }

    DEBUG2 && print "poe:/IKC/$e to '", specifier_name($to), "'\n";

    # This way the thunk session will proxy a request back to us
    if($sender)
    {
        $sender=$sender->ID if ref $sender;
        $msg->{from}={  kernel=>$self->{poe_kernel}->ID,
                        session=>$sender,
                        state=>'IKC:proxy',
                     };
    }

    # This is where we should recurse $msg->{params} to turn anything 
    # extravagant like a subref, $poe_kernel, session etc into a call back to 
    # us.

    # Get a list of channels to send the message to
    my @channels=$self->channel_list($name);
    unless(@channels)
    {
        warn (($name eq '*') 
                  ? "Not connected to any foreign kernels.\n" 
                  : "Unknown kernel '$name'.\n");
        return 0;
    }


    # now send the message over the wire
    # hmmm.... i wonder if this could be stream-lined into a direct call
    my $count=0;
    my $rsvp;
    $rsvp=$msg->{rsvp} if exists $msg->{rsvp};
    foreach my $channel (@channels)
    {
        # We need to be able to access this state w/out forcing folks
        # to use publish
        if($rsvp)
        {
            DEBUG && print "Allow $rsvp->{session}/$rsvp->{state} once\n";
            $self->{rsvp}{$rsvp->{session}}{$rsvp->{state}}++;
        }

        DEBUG2 && print "Sending to '$channel'...";
        if($kernel->call($channel, 'send', $msg))
        {
            $count++;
            DEBUG2 && print " done.\n";
        } else
        {
            DEBUG2 && print " failed.\n";
            $self->{rsvp}{$rsvp->{session}}{$rsvp->{state}}-- if $rsvp;
        }

    }

    DEBUG2 && print specifier_name($to), " sent to $count kernel(s).\n";
    DEBUG and do {warn "send_msg failed!" unless $count};
    return $count;
}

#----------------------------------------------------
## Turn a kernel name into a list of possible channels
sub channel_list
{
    my($self, $name)=@_;

    if($name eq '*') {                              # all kernels
        return values %{$self->{channel}}; 
    }  
    if(exists $self->{kernel}{$name}) {             # kernel alias
        my $t=$self->{kernel}{$name};
        unless(exists $self->{channel}{$t}) {
            die "What happened to channel $t!";
        }
        return ($self->{channel}{$t})
    }

    if(exists $self->{channel}{$name}) {            # kernel ID
        return ($self->{channel}{$name})
    }
    return ();    
}

#----------------------------------------------------
# Send a request to the foreign kernel
sub post
{
    my($self, $to, $params, $sender) = @_;

    $to="poe:$to" unless ref $to or $to=~/^poe:/;

    $self->send_msg({params=>$params, 'event'=>$to}, $sender);
}

#----------------------------------------------------
# Send a request to the foreign kernel and ask it to provide 
# the state's return value back
sub call
{
    my($self, $to, $params, $rsvp, $sender)=@_;

    $to="poe:$to"     if $to   and not ref $to   and $to!~/^poe:/;
    $rsvp="poe:$rsvp" if $rsvp and not ref $rsvp and $rsvp!~/^poe:/;

    my $t=specifier_parse($rsvp);
    unless($t)
    {
        if($rsvp)
        {
            warn "Bad 'rsvp' parameter '$rsvp' in poe:/IKC/call\n";
        } else
        {
            warn "Missing 'rsvp' parameter in poe:/IKC/call\n";
        }
        return;
    }
    $rsvp=$t;
    unless($rsvp->{state})
    {
        warn "rsvp state not set in poe:/IKC/call\n";
        return;
    }

    # Question : should $rsvp->{session} be forced to be the sender?
    # or will we allow people to point callbacks to other poe:kernel/sessions
    $rsvp->{session}||=$sender->ID if ref $sender;    # maybe a session ID?
    if(not $rsvp->{session})                            # no session alias
    {
        die "IKC call requires session IDs, please patch your version of POE\n";
    }
    DEBUG2 && print "RSVP is ", specifier_name($rsvp), "\n";

    $self->send_msg({params=>$params, 'event'=>$to, 
                     rsvp=>$rsvp
                    }, $sender
                   );
}

##############################################################################
# publish/retract/subscribe mechanism of setting up foreign sessions

#----------------------------------------------------
sub publish
{
    my($self, $session, $states)=@_;

    if(not ref $session)
    {
        $session||=$self->{poe_kernel}->ID_lookup($session);
    }
    unless($session)
    {
        carp "You must specify the session that publishes these states";
        return 0;
    }

    $self->{'local'}->{$session}||={};
    my $p=$self->{'local'}->{$session};

    die "\$states isn't an array ref" unless ref($states) eq 'ARRAY';
    foreach my $q (@$states)
    {
        DEBUG && print "Published poe:/$session/$q\n";
        $p->{$q}=1;
    }
    return 1;
}

#----------------------------------------------------
sub retract
{
    my($self, $session, $states)=@_;

    my $sid=$session;
    if(not ref $session)
    {
        $sid||=$self->{poe_kernel}->ID_lookup($session);
    }
    unless($sid)
    {
        carp "You must specify the session that publishes these states";
        return 0;
    }

    unless($self->{'local'}{$sid})
    {
        carp "Session didn't publish anything";
        return 0;
    }

    my $p=$self->{'local'}{$sid};
    foreach my $q (@$states)
    {
        delete $p->{$q};
    }
    delete $self->{'local'}{$sid} unless %$p;
    return 1;
}

#----------------------------------------------------
# Subscribing is in two phases
# 1- we call a IKC/do_you_have to the foreign kernels
# 2- the foreign responds with the session-specifier (if it has published it)
#
# We create a unique state for the callback for each subscription request
# from the user session.  It keeps count of how many subscription receipts
# it receives and when they are all subscribed, it localy posts the callback
# event.  
#
# If more then one kernel sends a subscription receipt
sub subscribe
{
    my($self, $sessions, $callback, $s_id)=@_;
    my($kernel)=@{$self}{qw(poe_kernel)};

    $s_id||=join '-', caller;

    my($ses, $s, $fiddle);
                                # unique identifier for this request
    my $unique="IKC:receipt $s_id $callback";  
    my $id=$kernel->ID;

    my $count;
    foreach my $spec (@$sessions)
    {
        $ses=specifier_parse($spec);   # Session specifier
                                    # Create the subscription receipt state
        $kernel->state($unique.$spec, 
                       sub {
                          _subscribe_receipt($self, $unique, $spec, $_[ARG0])
                       } 
                      );
        $kernel->delay($unique.$spec, 60);  # timeout

        if($ses->{kernel})
        {
            $count=$self->send_msg(
                    {event=>{kernel=>$ses->{kernel}, session=>'IKC', 
                                state=>'do_you_have'
                            },
                     params=>[$ses, $id],
                     rsvp=>{kernel=>$id, session=>'IKC', state=>$unique.$spec}
                    }
                 );
            # TODO What if this post failed?  Session that posted this would
            # surely want to know
        } else
        {                       # Bleh.  User shouldn't be that dumb       
            die "You can't subscribe to a session within the current kernel.";
        }
        

        if($callback)           # We need to keep some information around
        {                       # for when the subscription receipt comes in
            $self->{subscription_callback}{$unique}||=
                        {   callback=>$callback, 
                            sessions=>{}, yes=>[], count=>0, 
                            states=>{},
                        };
            $fiddle=$self->{subscription_callback}{$unique};
            $fiddle->{states}{$unique.$spec}=$count;
            $fiddle->{count}+=($count||0);
            $fiddle->{sessions}->{$spec}=1;
            if(not $count)
            {
                $fiddle->{count}++;
                $kernel->yield($unique.$spec);
            } else
            {
                DEBUG && print "Sent $count subscription requests for [$spec]\n";
            }
        }
    }

    return 1;
}

#----------------------------------------------------
# Subscription receipt
# All foreign kernel's that have published the desired session
# will send back a receipt.  
# Others will send a "NOT".
# This will cause problems when the Proxy session creates an alias :(
#
# Callback is called we are "done".  But what is "done"?  When at least
# one remote kernel has allowed us to subscribe to each session we are
# waiting for.  However, at some point we should give up.
# 
# Scenarios :
# one foreign kernel says 'yes', one 'no'.
#   - 'yes' creates a proxy
#   - 'no' decrements wait count 
#       ... callback is called with session specifier
# 2 foreign kernels says 'yes'
#   - first 'yes' creates a proxy
#   - 2nd 'yes' should also create a proxy!  alias conflict (for now)
#       ... callback is called with session specifier
# one foreign kernel says 'no', and after, another says yes
#   - first 'no' decrements wait count
#   - second 'no' decrements wait count
#       ... Subscription failed!  callback is called with specifier
# no answers ever came...
#   - we wait forever :(

sub _subscribe_receipt
{
    my($self, $unique, $spec, $ses)=@_;
    my $accepted=1;

    if(not $ses or not ref $ses)
    {
        warn "Refused to subscribe to $spec\n";
        $accepted=0;
    } else
    {
        $ses=specifier_parse($ses);
        die "Bad state" unless $ses;

        DEBUG && print "Create proxy for ", specifier_name($ses), "\n";
        my $proxy=create_ikc_proxy($ses->{kernel}, $ses->{session});

        push @{$self->{remote}{$ses->{kernel}}}, $proxy;
    }

    # cleanup the subscription request
    if(exists $self->{subscription_callback}{$unique})
    {
        DEBUG && print "Subscription [$unique] callback... ";
        my $fiddle=$self->{subscription_callback}{$unique};

        if($fiddle->{sessions}->{$spec} and $accepted)
        {
            delete $fiddle->{sessions}->{$spec};
            push @{$fiddle->{yes}}, $spec;
        }

        $fiddle->{count}-- if $fiddle->{count};
        if(0==$fiddle->{count})
        {
            DEBUG && print "yes.\n";
            delete $self->{subscription_callback}{$unique};
            $fiddle->{callback}->($fiddle->{yes});
        } else
        {
            DEBUG && print "no, $fiddle->{count} left.\n";
        }
        
        $fiddle->{states}{$unique.$spec}--;
        if($fiddle->{states}{$unique.$spec}<=0)
        {
            # this state is no longer needed
            $self->{poe_kernel}->state($unique.$spec);
            delete $fiddle->{states}{$unique.$spec};
        }
    } else
    {
        # this state is no longer needed
        $$self->{poe_kernel}->state($unique.$spec);
    }
}

#----------------------------------------------------
sub unsubscribe
{
    my($self, $states)=@_;
    $states=[$states] unless ref $states;
    return unless @$states;
    croak "Not done";
}

#----------------------------------------------------
sub ping
{
    "PONG";
}

##############################################################################
# These are Thunks used to post the actual state on behalf of the foreign
# kernel.  Currently, the thunks are used as a "proof of concept" and
# to accur extra over head. :)
# 
# The original idea was to make sure that $_[SENDER] would be something
# valid to the posted state.  However, garbage collection becomes a problem
# If we are to allow the poste session to "hold on to" $_[SENDER]. 
#
# Having the Responder save all Thunks until the related foreign connection
# disapears would be wasteful.  Or, POE could use soft-refs to track
# active sessions and the thunk would "kill" itself in _stop.  This
# would force POE to require 5.005, however.
#

# Export thunk the quick way.
*_thunked_post=\&POE::Component::IKC::Responder::Thunk::thunk;
package POE::Component::IKC::Responder::Thunk;

use strict;
use POE qw(Session);
use Data::Dumper;

sub DEBUG { 0 }

{
    my $name=__PACKAGE__.'00000000';
    $name=~s/\W//g;
    sub thunk
    {
        POE::Session->new(__PACKAGE__, [qw(_start _stop _default)], 
                                       [$name++, @_]
                         );
    }
}

sub _start
{
    my($kernel, $heap, $name, $caller, $args, $foreign)=
                @_[KERNEL, HEAP, ARG0, ARG1, ARG2, ARG3];
    $heap->{rsvp}=$foreign;
    $heap->{name}=$name;

    DEBUG && print "$name created\n";

    if($caller)                             # foreign session wants return
    {
        my $ret=$kernel->call(@$args);
        if(defined $ret) {
            DEBUG && print "Posted response '$ret' to ", Dumper $caller;
            $kernel->post('IKC', 'post', $caller, $ret) ;
        }
    } else
    {
        $kernel->call(@$args);
    }
    return;
}

sub _stop
{
    DEBUG && print "$_[HEAP]->{name} delete\n";
}

sub _default
{
    my($kernel, $heap, $sender, $state, $args)=
            @_[KERNEL, HEAP, SENDER, ARG0, ARG1];
    return if $state =~ /^_/;

    warn "Attempt to respond to a foreign post with $state\n"
        if not $heap->{rsvp};

    $POE::Component::IKC::Responder::ikc->send_msg(
                {params=>[$state, $args], to=>$heap->{rsvp}}, $sender
              );
}

1;
__END__

=head1 NAME

POE::Component::IKC::Responder - POE IKC state handler

=head1 SYNOPSIS

    use POE;
    use POE::Component::IKC::Responder;
    create_ikc_responder();
    ...
    $kernel->post('IKC', 'post', $to_state, $state);

    $ikc->publish('my_name', [qw(state1 state2 state3)]);

=head1 DESCRIPTION

This module implements an POE IKC state handling.  The responder handles
posting states to foreign kernels and calling states in the local kernel at
the request of foreign kernels.

There are 2 interfaces to the responder.  Either by sending states to the 
'IKC' session or the object interface.  While the latter is faster, the
better behaved, because POE is a cooperative system.

=head1 STATES/METHODS

=head2 C<post>

Sends an state request to a foreign kernel.  Returns logical true if the
state was sent and logical false if it was unable to send the request to the 
foreign kernel.  This does not mean that the foreign kernel was able to 
post the state, however.  Parameters are as follows :

=over 2

=item C<foreign_state>

Specifier for the foreign state.   See L<POE::Component::IKC::Specifier>.

=item C<parameters>

A reference to anything you want the foreign state to get as ARG0.  If you
want to specify several parameters, use an array ref and have the foreign
state dereference it.

    $kernel->post('IKC', 'post', 
        {kernel=>'Syslog', session=>'logger', state=>'log'},
        [$faculty, $priority, $message];

or

    $ikc->post('poe://Syslog/logger/log', [$faculty, $priority, $message]);

This logs an state with a hypothetical logger.  

=back

=head2 C<call>

This is identical to C<post>, except it has a 3rd parameter that describes
what state should receive the return value from the foreign kernel.

    $kernel->post('IKC', 'call', 
                'poe://Pulse/timeserver/time', '',
                'poe:get_time');

or

    $ikc->call({kernel=>'Pulse', session=>'timeserver', state=>'time'},
                '', 'poe:/me/get_time');

This asks the foreign kernel 'Pulse' for the time.  'get_time' state in the
current session is posted with whatever the foreign state returned.

=over 3

=item C<foreign_state>

Identical to the C<post> C<foreign_state> parameter.

=item C<parameters>

Identical to the C<post> C<parameters> parameter.

=item C<rsvp>

Event identification for the callback.  That is, this state is called with
the return value of the foreign state.  Can be a C<foreign_state> specifier
or simply the name of an state in the current session.

=back

    $kernel->call('IKC', 'post', 
        {kernel=>'e-comm', session=>'CC', state=>'check'},
        {CC=>$cc, expiry=>$expiry}, folder=>$holder},
        'is_valid');
    # or
    $ikc->call('poe:/e-comm/CC/check',
        {CC=>$cc, expiry=>$expiry}, folder=>$holder},
        'poe:/me/is_valid');

This asks the e-comm server to check if a credit card number is "well
formed".  Yes, this would probably be massive overkill. 

The C<rsvp> state does not need to be published.  IKC keeps track of the
rsvp state and will allow the foreign kernel to post to it.

=head2 C<default>

Sets the default foreign kernel.  You must be connected to the foreign
kernel first.

Unique parameter is the name of the foreign kernel kernel.

Returns logical true on success.

=head2 C<register>

Registers foreign kernel names with the responder.  This is done during the
negociation phase of IKC and is normaly handled by C<IKC::Channel>.  Will
define the default kernel if no previous default kernel exists.

Unique parameter is either a single kernel name or an array ref of kernel
names to be registered.

=head2 C<unregister>

Unregisters one or more foreign kernel names with the responder.  This is
done when the foreign kernel disconnects by C<IKC::Channel>. If this is the
default kernel, there is no more default kernel.

Unique parameter is either a single kernel name or an array ref of kernel
names to be unregistered.


=head2 C<publish>

Tell IKC that some states in the current session are available for use by
foreign sessions.

=over 2

=item C<session>

A session alias by which the foreign kernels will call it.  The alias must
already have been registered with the local kernel.

=item C<states>

Arrayref of states that foreign kernels may post.

    $kernel->post('IKC', 'publish', 'me', [qw(foo bar baz)]);
    # or
    $ikc->publish('me', [qw(foo bar baz)]);

=back

=head2 C<retract>

Tell IKC that some states should no longer be available for use by foreign
sessions.  You do not have to retract all published states.

=over 2

=item C<session>

Same as in C<publish>

=item C<states>

Same as in C<publish>

    $kernel->post('IKC', 'retract', 'me', [qw(foo)]);
    # or
    $ikc->retract('me', [qw(foo)]);

=back


=head2 C<subscribe>

Subscribe to foreign sessions or states.  When you have subscribed to a
foreign session, a proxy session is created on the local kernel that will
allow you to post to it like any other local session.

=over 3

=item C<specifiers>

An arrayref of the session or state specifiers you wish to subscribe to. 
While the wildcard '*' kernel may be used, only the first kernel that
acknowledges the subscription will be proxied.

=item C<callback>

Either an state (for the state interface) or a coderef (for the object
interface) that is posted (or called) when all subscription requests have
either been replied to, or have timed out.

When called, it has a single parameter, an arrayref of all the specifiers
that IKC was able to subscribe to.  It is up to you to see if you have
enough of the foreign sessions or states to get the job done, or if you
should give up.

While C<callback> isn't required, it makes a lot of sense to use it because
it is only way to find out when the proxy sessions become available.

Example :

    $ikc->subscribe([qw(poe://Pulse/timeserver)], 
            sub { $kernel->post('poe://Pulse/timeserver', 'connect') });

(OK, that's a bad example because we don't check if we actually managed to
subscribe or not.)

    $kernel->post('IKC', 'subscribe', 
                    [qw(poe://e-comm/CC poe://TouchNet/validation
                        poe://Cantax/JDE poe://Informatrix/JDE)
                    ],
                    'poe:subscribed',
                  );
    # and in state 'subscribed'
    sub subscribed
    {
        my($kernel, $specs)=@_[KERNEL, ARG0];
        if(@$specs != 4)
        {
            die "Unable to find all the foreign sessions needed";
        }
        $kernel->post('poe://Cantax/JDE', 'write', {...somevalues...});
    }                
    
This is a bit of a mess.  You might want to use the C<subscribe> parameter
to C<create_ikc_client> instead.

Subscription receipt timeout is currently set to 120 seconds.

=head2 C<unsubscribe>

Reverse of the C<subscribe> method.  However, it is currently not
implemented.


=head1 EXPORTED FUNCTIONS

=head2 C<create_ikc_responder>

This function creates the Responder session and object.  However, you don't
need to call this directly, because C<IKC::Client> or C<IKC::Server> does
this for you.

=head1 BUGS

Sending session references and coderefs to a foreign kernel is a bad idea :)  At some
point it would be desirable to recurse through the paramerters and and turn
any session references into state specifiers.

C<rsvp> state in call is a bit problematic.  IKC allows it to be posted to
once, but doesn't check to see if the foreign kernel is the right one.

C<retract> does not currently tell foreign kernels that have subscribed to a
session/state that it has been retracted.

C<call()ing> a state in a proxied foreign session doesn't work, for obvious
reasons.

=head1 AUTHOR

Philip Gwyn, <fil@pied.nu>

=head1 SEE ALSO

L<POE>, L<POE::Component::IKC::Server>, L<POE::Component::IKC::Client>

=cut
