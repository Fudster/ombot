#!/usr/bin/env perl
# Omegle IRC bot by Matthew Barksdale 
# Version: 0.1-dev

BEGIN {
    use FindBin qw($Bin);
    unshift(@INC, "$Bin/../lib");
}

use strict;
use warnings;
use feature qw(say switch);

use IO::Async;
use IO::Async::Loop;
use IO::Async::Stream;
use IO::Socket::IP;
use IO::Async::Timer::Countdown;

use Net::Async::Omegle;
use Net::Async::HTTP;
use Config::JSON;
use URI;

my ($mainLoop, $configFile, $config);
my (%sockets, %streams);
my ($om, $http);
my $INSESSION = 0;
my $COOLDOWN = 0;

# Config file? Default to bot.conf unless otherwise told
$configFile = $ARGV[0] || "$Bin/../etc/bot.conf";

# Let's make a new Config::JSON based on config file
$config = Config::JSON->new($configFile);

# Initialization subroutine
sub bot_init {
    # Create loop
    $mainLoop = IO::Async::Loop->new;
    foreach my $sockName (qw/om you/)
    {
        $sockets{$sockName} = IO::Socket::IP->new(
            PeerAddr  => $config->get('host'),
            PeerPort  => $config->get('port'),
            LocalAddr => $config->get('bind'),
            Timeout   => 10
        );
        $streams{$sockName} = IO::Async::Stream->new(
            handle => $sockets{$sockName},
            on_read => sub {
                my ($self, $buffref, $eof) = @_;
                while ($$buffref =~ s/^(.*)\n//)
                {
                    irc_parse($sockName, $1);
                }
                return 0;
            },
        );
        $mainLoop->add($streams{$sockName});
    }
    # Create Net::Async::Omegle object
    $om = Net::Async::Omegle->new();
    # Create Net::Async::HTTP object
    $http = Net::Async::HTTP->new;
    # Add to loop
    $mainLoop->add($om);
    $mainLoop->add($http);
    $om->init();
    # Send intros
    send_intro();
    # Let's go
    $mainLoop->run;
}

# Get stream by id
sub stream_by_id
{
    my $id = shift;
    return $streams{$id} if defined $streams{$id};
    return 0; # No match
}

# Send data to IRC
sub irc_send
{
    my ($to, $data) = @_;
    my $streamObj = stream_by_id($to);
    return if !$streamObj; # Bail, no match was found (???)
    chomp $data;
    $streamObj->write($data."\r\n");
    say "[$to] >> $data" if $config->get('debug');
}

# Send IRC intro
sub send_intro
{
    # Send IRC intros
    my %nicks = ('you' => $config->get('you/nick'), 'om' => $config->get('ombot/nick'));
    foreach (qw/om you/)
    {
        irc_send($_, "NICK $nicks{$_}");
        irc_send($_, "USER omegle * * :Omegle IRC Bot");
    }
}

# Parse IRC
sub irc_parse
{
    my ($from, $data) = @_;
    my $streamObj = stream_by_id($from);
    return if !$streamObj; # Bail, no match was found (???)
    my @ex = split(' ', $data); # Space split
    irc_send($from, "PONG $ex[1]") if $ex[0] eq 'PING';
    irc_send($from, "JOIN ".$config->get('channel')) if $ex[1] eq '001';
    say "[$from] << $data" if $config->get('debug');
    if ($ex[1] eq 'PRIVMSG' and $from eq 'om')
    {
        my $confNick = ($config->get('ombot/changenicks') ? $config->get('ombot/sessionnick') : $config->get('ombot/nick'));
        $ex[3] = substr $ex[3], 1;
        my $params = join ' ', @ex[4..$#ex];
        given (lc($ex[3]))
        {
            when (/(!|\.)(say|send)/)
            {
                if (!$INSESSION)
                {
                    om_say("There is currently no session in progress.");
                    return;
                }
                you_say($params);
            }
            when (/($confNick)(:|,| )/i)
            {
                if (!$INSESSION)
                {
                    om_say("There is currently no session in progress.");
                    return;
                }
                you_say($params);
            }
            when (/(!|\.)(captcha|submit)/)
            {
                $om->submit_captcha($params);
            }
            when (/(!|\.)troll/)
            {
                if (!$INSESSION)
                {
                    om_say("There is currently no session in progress.");
                    return;
                }
                $http->do_request(
                    uri => URI->new($config->get('omegle/trollsrc')),
                    on_response => sub { you_say(shift->decoded_content); },
                    on_error => sub { om_say("Error getting troll: ".shift); }
                );
            }
            when (/(!|\.)(start|begin)/)
            {
                if ($INSESSION)
                {
                    om_say("A session is already in progress.");
                    return;
                }
                if ($COOLDOWN)
                {
                    om_say("Please wait a few seconds before starting a new session.");
                    return;
                }
                my %args = (
                    on_error => \&om_error,
                    on_connect => \&om_connect,
                    on_disconnect => \&om_disconnect,
                    on_chat  => \&om_chat,
                    on_type  => \&om_type,
                    on_stoptype => \&om_stoptype,
                    on_got_id => \&om_gotid,
                    on_wantcaptcha => \&om_wantcaptcha,
                    on_gotcaptcha => \&om_gotcaptcha,
                    on_badcaptcha => \&om_badcaptcha,
                    on_commonlikes => \&om_commonlikes
                );
                if (defined $ex[4])
                {
                    my @array;
                    push(@array, "\"$_\"") foreach @ex[4..$#ex];
                    my $likes = join ', ', @array;
                    $args{topics} = "[$likes]";
                    $args{use_likes} = 1;
                }
                $INSESSION = $om->new(%args);
                $INSESSION->start();
            }
            when (/(!|\.)asl/)
            {
                if (!$INSESSION)
                {
                    om_say("There is currently no session is in progress.");
                    return;
                }
                my @ages = ($config->get('omegle/asl/low')..$config->get('omegle/asl/high'));
                my @sexes = ('m', 'f');
                my @location = ('USA', 'AU', 'Canada', 'Netherlands', 'New Zealand', 'Germany', 'United Kingdom', 'France', 'New Jersey', 'California', 'Utah', 'New York', 'Florida', 'Virginia');
                my $a = $ages[int rand scalar @ages];
                my $s = $sexes[int rand scalar @sexes];
                my $l = $location[int rand scalar @location];
                if (defined $ex[4]) { $s = $ex[4]; }
                you_say("$a / $s / $l");
            }
            when (/(!|\.)(stop|end)/)
            {
                if (!$INSESSION)
                {
                    om_say("There is currently no session is in progress.");
                    return;
                }
                if ($config->get('omegle/quitmessage'))
                {
                    $INSESSION->say($config->get('omegle/quitmessage'));
                }
                $INSESSION->disconnect();
                $INSESSION = 0;
                irc_send('om', "NICK :".$config->get('ombot/nick'));
                $COOLDOWN = 1;
                my $timer = IO::Async::Timer::Countdown->new(delay => 10, on_expire => sub { $COOLDOWN = 0; });
                $mainLoop->add($timer);
                $timer->start;
           }
        }
    }
}

# Bot say
sub om_say
{
    my $data = shift;
    my $chan = $config->get('channel');
    irc_send('om', "PRIVMSG $chan :$data");
}

# You say
sub you_say
{
    my $data = shift;
    my $chan = $config->get('channel');
    $INSESSION->say($data);
    irc_send('you', "PRIVMSG $chan :$data");
}

# 'got_id' event
sub om_gotid { shift; om_say("Omegle started with ID ".shift); }

# 'connect' event
sub om_connect
{
   om_say("Stranger connected.");
   if ($config->get('ombot/changenicks'))
   {
       irc_send('om', "NICK ".$config->get('ombot/sessionnick'));
   }
}
# 'disconnect' event
sub om_disconnect
{
   om_say("Stranger disconnected.");
   if ($config->get('ombot/changenicks'))
   {
       irc_send('om', "NICK ".$config->get('ombot/nick'));
   }
   $INSESSION = 0;
}

# 'error' event
sub om_error { shift; om_say("Omegle sent an error ".shift); }

# 'wantcaptcha' event
sub om_wantcaptcha { om_say("Omegle wants CAPTCHA"); }

# 'gotcaptcha' event
sub om_gotcaptcha { shift; om_say("Fill out CAPTCHA here: ".shift); }

# 'badcaptcha' event
sub om_badcaptcha { om_say("CAPTCHA incorrect."); }

# 'commonlikes' event
sub om_commonlikes { 
    my ($self, @interestArray) = @_;
    my $common = join ',', $interestArray[0][0];
    om_say("\001ACTION is interested in ".$common."\001");
}

# 'type' event
sub om_type { 
    if ($config->get('ombot/changenicks'))
    {
        om_say("\001ACTION is typing...\001");
    }
    else
    {
        om_say("Stranger is typing...");
    }
}

# 'stoptype' event
sub om_stoptype {
    if ($config->get('ombot/changenicks'))
    {
        om_say("\001ACTION stopped typing.\001");
    }
    else
    {
        om_say("Stranger stopped typing.");
    }
}

# 'chat' event
sub om_chat {
    my ($self, $message) = @_;
    chomp $message;
    if ($config->get('ombot/changenicks'))
    {
        om_say($message);
    }
    else
    {
        om_say("Stranger: $message");
    }
}

# Let's go
bot_init();
