# GeoPresence - presence and location automation for FHEM.
# SPDX-License-Identifier: GPL-3.0-only
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program in the LICENSE file. If not, see
# <https://www.gnu.org/licenses/>.

package main;

use strict;
use warnings;
no warnings 'redefine'; # FHEM reload evaluates this file again in package main.
use utf8;
use JSON::PP ();
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(decode_base64);
use Encode qw(decode encode FB_CROAK);
use Time::Local qw(timegm timelocal);
use Time::HiRes ();
use POSIX ();
use IO::Socket::INET ();
use Errno qw(EAGAIN EWOULDBLOCK EINTR);

our (%defs, %attr, %data, %selectlist, $init_done, $readingFnAttributes, $unicodeEncoding);
our (%FW_webArgs, $FW_ME, $FW_subdir);

# Only controller devices own runtime state. Readings are ordinary FHEM snapshots,
# never an executable queue. Only qualified unfinished trips may resume.
my $GP_DEFAULT_WEBHOOK_PORT = 8090;
my %GP_DEFAULT = (
    action_max_age => 90, future_tolerance => 30, reorder_window => 2,
    departure_grace => 60, minimum_away => 60, phone_absence_window => 180,
    phone_poll => 5, motion_max_age => 180, approach_timeout => 600,
    zone_display_max_age => 43200, actor_timeout => 60, departure_margin => 200,
    trip_resume_max_age => 172800,
    arrival_wait_walking => 60, arrival_wait_running => 30, arrival_wait_cycling => 20,
    arrival_wait_automotive => 10, arrival_wait_unknown => 60, arrival_motion_max_age => 30,
);
my %GP_ATTRS = (
    controller => [qw(webhookPath webhookPort webhookBindAddress webhookAllowedPeers logFile debugLog), sort keys %GP_DEFAULT],
    resident => [qw(sourceMode deviceId webhookUser
        phoneProxies phoneSignalMode allowDoor allowGarage)],
    location => [qw(zoneId label groups)],
    action => [qw(target command contact feedbackDevice positionSignalMode stateDevice upperContact
        lowerContact message priority channel)],
    rule => [qw(enabled trigger residents locations locationGroup afterExit arrivalFilter action cooldown)],
);
my %GP_ALLOWED = map { $_ => 1 } map { @$_ } values %GP_ATTRS;
my %GP_LEGACY_ATTR = map {$_=>1} qw(mode operatingMode role condition);
my %GP_DISPLAY_ATTR = map {$_=>1} qw(alias room group icon verbose comment debugLog logFile);
my %GP_ENUMS = (
    debugLog => [qw(auto 0 1)], sourceMode => [qw(geofency_phone geofency_only phone_only)],
    phoneSignalMode => [qw(state measurement)], positionSignalMode => [qw(state measurement)], enabled => [qw(1 0)],
    allowDoor => [qw(0 1)], allowGarage => [qw(0 1)],
    trigger => [qw(arrival enter exit)],
    arrivalFilter => [qw(any vehicle)],
    channel => [qw(0 1 2 10)], priority => [qw(0 1 2)],
);
my %GP_ACTION_ATTRS = (
    door_open => [qw(target command contact feedbackDevice positionSignalMode)],
    garage_open => [qw(target command stateDevice upperContact lowerContact positionSignalMode)],
    notify => [qw(message priority channel)],
    switch_on => [qw(target command)],
);
my $GP_JSON = JSON::PP->new->canonical->utf8;
my $GP_CHECKPOINT_JSON = JSON::PP->new->canonical->ascii;
my @GP_CHECKPOINT_TRIP_FIELDS = qw(id start home_exit scope armed away_time away_reason actions exits);
my @GP_CHECKPOINT_STATE_FIELDS = qw(location position_time boundary zones members zone_visits group_visits motion motion_time automotive);
my $GP_PHONE_DEPARTURE_REASON = 'Home exit and qualified phone absence';
my %GP_AUTH;

# GP_UsesSource: Check whether a resident profile enables the requested source.
sub GP_UsesSource {
    my ($mode,$source)=@_;
    $mode //= 'geofency_phone';
    return ($source eq 'phone' ? $mode =~ /\A(?:geofency_phone|phone_only)\z/
        : $mode =~ /\A(?:geofency_phone|geofency_only)\z/) ? 1:0;
}

# GP_ResidentAttrEnabled: Check whether an attribute applies to the resident's selected sources.
sub GP_ResidentAttrEnabled {
    my ($mode,$key)=@_;
    return GP_UsesSource($mode,'phone') if $key =~ /\A(?:phoneProxies|phoneSignalMode)\z/;
    return GP_UsesSource($mode,'geo') if $key =~ /\A(?:deviceId|webhookUser|allowDoor|allowGarage)\z/;
    return 1;
}

# GP_RuleAttrEnabled: Check whether a rule attribute applies to its trigger and selector.
sub GP_RuleAttrEnabled {
    my ($name,$key)=@_;
    my $trigger=GP_Attr($name,'trigger','');
    return 1 unless $trigger =~ /\A(?:arrival|enter|exit)\z/;
    return $trigger eq 'arrival' if $key eq 'arrivalFilter';
    return $trigger ne 'arrival' && !length GP_Attr($name,'locationGroup','') if $key eq 'locations';
    return $trigger ne 'arrival' && !length GP_Attr($name,'locations','') if $key eq 'locationGroup';
    return 1;
}

# GP_AttrSpec: Format an attribute name with its supported widget choices.
# These lists describe the normal FHEMWEB widgets; they never write attributes,
# publish events or change runtime permissions. Keep enum validation in sync.
sub GP_AttrSpec {
    my ($key)=@_;
    return $GP_ENUMS{$key} ? $key.':'.join(',',@{$GP_ENUMS{$key}}) : $key;
}

# GP_MatchingAttrs: Match attribute names against a deletion pattern without propagating regex errors.
sub GP_MatchingAttrs {
    my ($key,@keys)=@_;
    return eval {grep {!length($key) || /^$key$/} @keys};
}

# GP_ConfigAttrKeys: Identify protected configuration keys affected by an attribute change.
# The pre-commit guard protects changes to supported business parameters.
# Global invalidation also covers display names and obsolete validation inputs.
sub GP_ConfigAttrKeys {
    my ($d,$key,$deleting)=@_;
    return () if $key eq 'debugLog' || $key eq 'logFile';
    return ($key) if $GP_ALLOWED{$key};
    return () unless $deleting;
    return GP_MatchingAttrs($key,grep {$_ ne 'debugLog' && $_ ne 'logFile'}
        @{$GP_ATTRS{$d->{SUBTYPE}//''}//[]});
}

# GP_UpdateAttrLists: Refresh subtype-specific FHEMWEB attribute widgets and device choices.
sub GP_UpdateAttrLists {
    my ($only)=@_;
    my (@devices,@proxies,%choices,%groups);
    my %references=(action=>'action',residents=>'resident',locations=>'location');
    for my $name (sort keys %defs) {
        my $d=$defs{$name};
        # FHEM sensor names may start with digits, unlike GeoPresence defines.
        # Exclude widget separators and HTML metacharacters from choices.
        next unless $name =~ /\A[A-Za-z0-9_.-]+\z/;
        push @proxies,$name if ($d->{TYPE}//'') eq 'PRESENCE';
        next unless ($d->{TYPE}//'') eq 'GeoPresence' && $GP_ATTRS{$d->{SUBTYPE}//''};
        push @devices,$d;
        push @{$choices{$d->{CONTROLLER}//''}{$d->{SUBTYPE}}},$name;
        if (($d->{SUBTYPE}//'') eq 'location') {
            $groups{$d->{CONTROLLER}//''}{$_}=1 for GP_List(GP_Attr($name,'groups',''));
        }
    }
    for my $d ($only ? ($only) : @devices) {
        my $kind=$d->{SUBTYPE};
        # During config loading accept old, unused action attributes as before.
        # INITIALIZED narrows the offered list; existing values remain deletable.
        my $keys=$kind eq 'action' && $init_done
            ? $GP_ACTION_ATTRS{$d->{ACTIONTYPE}} : $GP_ATTRS{$kind};
        my @spec;
        for my $key (@$keys) {
            next if $kind eq 'resident' && $init_done
                && !GP_ResidentAttrEnabled(GP_Attr($d->{NAME},'sourceMode','geofency_phone'),$key);
            next if $kind eq 'rule' && $init_done && !GP_RuleAttrEnabled($d->{NAME},$key);
            my $entry=GP_AttrSpec($key);
            if ($key eq 'command' && ($d->{ACTIONTYPE}//'') ne 'notify') {
                $entry='command:select,'.($d->{ACTIONTYPE} eq 'door_open' ? 'lock#unlocked':'on');
            }
            if (exists($references{$key}) || $key eq 'phoneProxies') {
                my @names=$key eq 'phoneProxies' ? @proxies
                    : @{$choices{$d->{CONTROLLER}//''}{$references{$key}}//[]};
                # Preserve visible stale references so opening an editor cannot
                # silently discard them; validate still reports missing devices.
                my %names=map {$_=>1} (@names,grep {/\A[A-Za-z0-9_.-]+\z/} GP_List(GP_Attr($d->{NAME},$key,'')));
                @names=sort keys %names;
                $entry=$key.($key eq 'action' ? ':select,,':':multiple-strict,').join(',',@names) if @names;
            }
            if ($key eq 'locationGroup' || $key eq 'afterExit') {
                my @tags=sort keys %{$groups{$d->{CONTROLLER}//''}//{}};
                my @names=$key eq 'locationGroup' ? @tags : ((map {'group:'.$_} @tags),
                    map {'location:'.$_} @{$choices{$d->{CONTROLLER}//''}{location}//[]});
                push @names,GP_Attr($d->{NAME},$key,'') if length GP_Attr($d->{NAME},$key,'');
                my %seen; @names=grep {!$seen{$_}++} @names;
                $entry=$key.':select,,'.join(',',@names) if @names;
            }
            push @spec,$entry;
        }
        $d->{'.AttrList'}=join(' ',@spec,($readingFnAttributes//''));
    }
}

# GP_AuthKey: Derive a regex-safe key-store identifier from a resident name.
sub GP_AuthKey { return 'GeoPresence_auth_v2_'.sha256_hex($_[0]); }

# GP_AuthPath: Resolve the FHEM key-store path using the core's filename cleanup.
# FHEM treats key names as regex patterns. New keys use only a fixed prefix
# and hex digits; legacy names must be compared literally in the same file.
sub GP_AuthPath {
    my $file=GP_Attr('global','keyFileName','uniqueID');
    $file =~ s/\.\.//g;
    return GP_Attr('global','modpath','.').'/FHEM/FhemUtils/'.$file;
}

# GP_ReadAuth: Read the preferred password verifier with an exact-name legacy fallback.
sub GP_ReadAuth {
    my ($resident)=@_;
    my ($error,@lines)=FileRead(GP_AuthPath());
    return ($error,undef) if $error;
    my $current=GP_AuthKey($resident).':';
    my $old='GeoPresence_'.$resident.'_auth:';
    my $legacy;
    # Keep the first legacy value until the scan rules out a preferred key.
    # Even an empty preferred value prevents an old password from becoming valid.
    for my $line (@lines) {
        return (undef,substr($line,length $current)) if index($line,$current)==0;
        $legacy=substr($line,length $old) if !defined($legacy) && index($line,$old)==0;
    }
    return (undef,$legacy);
}

# GP_StoreAuth: Store or delete a password verifier and remove its exact legacy entries.
sub GP_StoreAuth {
    my ($resident,$secret)=@_;
    # Keep the core write semantics: legacy cleanup may fail after the new value is stored.
    my $error=setKeyValue(GP_AuthKey($resident),$secret);
    return $error if $error;
    my $file=GP_AuthPath();
    my @lines;
    ($error,@lines)=FileRead($file);
    return $error if $error;
    my $prefix='GeoPresence_'.$resident.'_auth:';
    my $count=@lines;
    @lines=grep {index($_,$prefix)!=0} @lines;
    return @lines==$count ? undef:FileWrite($file,@lines);
}

# GP_Auth: Cache credential lookup results while honoring a persisted migration failure.
sub GP_Auth {
    my ($resident)=@_;
    unless ($GP_AUTH{$resident}) {
        my $error=GP_Read($resident,'gp_auth_error','');
        $GP_AUTH{$resident}=$error ? [$error,undef] : [GP_ReadAuth($resident)];
    }
    return @{$GP_AUTH{$resident}};
}

# GeoPresence_Initialize: Register FHEM callbacks and reset existing controllers after a module reload.
sub GeoPresence_Initialize {
    my ($hash) = @_;
    $hash->{DefFn} = 'GeoPresence_Define';
    $hash->{UndefFn} = 'GeoPresence_Undef';
    $hash->{DeleteFn} = 'GeoPresence_Delete';
    $hash->{RenameFn} = 'GeoPresence_Rename';
    $hash->{SetFn} = 'GeoPresence_Set';
    $hash->{GetFn} = 'GeoPresence_Get';
    $hash->{AttrFn} = 'GeoPresence_Attr';
    $hash->{NotifyFn} = 'GeoPresence_Notify';
    $hash->{AttrList} = join(' ', map {GP_AttrSpec($_)} sort keys %GP_ALLOWED)
        . ' ' . ($readingFnAttributes // '');
    GP_UpdateAttrLists();
    # FHEM calls Initialize on reload; old callbacks may still be queued.
    for my $d (values %defs) {
        next unless ($d->{TYPE} // '') eq 'GeoPresence' && ($d->{SUBTYPE} // '') eq 'controller';
        GP_InvalidateDevices($d);
        GP_ResetController($d,'resume');
    }
}

# GP_Now: Return Unix time in seconds for observation dates and diagnostics.
sub GP_Now { return Time::HiRes::time(); }

# GP_Mono: Return monotonic seconds for elapsed-time budgets.
sub GP_Mono { return Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); }

# GP_CPU: Return process CPU time for timer diagnostics.
sub GP_CPU { my ($user,$system)=times; return $user+$system; }

# GP_Profile: Measure a timer phase while preserving return context and exceptions.
# Passive timing within a timer invocation only. Nested spans have exclusive
# self time, so a slow FHEM callback is not also charged to all its callers.
# Preserve the caller's context and exception; no commands or events are added.
sub GP_Profile {
    my ($c,$phase,$target,$code)=@_;
    my $work=$c->{helper}{gp_work};
    return $code->() unless $work;
    my $parent=$work->{frame};
    my $frame={children=>0};
    my $start=GP_Mono();
    my ($result,@result,$ok,$error);
    my $context=wantarray;
    {
        local $work->{frame}=$frame;
        local $@;
        $ok=eval {
            if (!defined $context) { $code->(); }
            elsif ($context) { @result=$code->(); }
            else { $result=$code->(); }
            1;
        };
        $error=$@ unless $ok;
    }
    my $elapsed=GP_Mono()-$start; $elapsed=0 if $elapsed<0;
    $parent->{children}+=$elapsed if $parent;
    my $self=$elapsed-$frame->{children}; $self=0 if $self<0;
    my $row=$work->{phases}{join('|',$phase,$target)}//={phase=>$phase,target=>$target,calls=>0,elapsed_ms=>0,self_ms=>0};
    $row->{calls}++; $row->{elapsed_ms}+=$elapsed*1000; $row->{self_ms}+=$self*1000;
    die $error unless $ok;
    return $context ? @result : $result;
}

# GP_Attr: Read an attribute with a fallback when no value is defined.
sub GP_Attr { return ($attr{$_[0]} // {})->{$_[1]} // $_[2]; }

# GP_List: Split a comma-separated attribute into nonempty entries.
sub GP_List { return grep { length } split /,/, ($_[0] // ''); }

# GP_Name: Validate a GeoPresence device name.
sub GP_Name { return defined($_[0]) && $_[0] =~ /\A[A-Za-z][A-Za-z0-9_.-]*\z/; }

# GP_Group: Validate a group name and its maximum length.
sub GP_Group { return GP_Name($_[0]) && length($_[0])<=64; }

# GP_Id: Validate a webhook user, device, or location identifier.
sub GP_Id { return defined($_[0]) && $_[0] =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/; }

# GP_Number: Recognize the decimal number format accepted by configuration and observations.
sub GP_Number { return defined($_[0]) && $_[0] =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/; }

# GP_IPv4: Validate a concrete IPv4 address and its octets.
sub GP_IPv4 {
    my ($address)=@_;
    return 0 unless defined($address) && $address =~ /\A(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}\z/;
    my @octets=split /\./,$address;
    return $octets[0]>0 && $octets[0]<224 && !grep {$_>255} @octets;
}

# GP_PeerListValid: Validate a bounded list of distinct allowed IPv4 peers.
sub GP_PeerListValid {
    my ($value)=@_;
    return 0 unless defined($value) && length($value);
    my @peers=split /,/,$value,-1;my %seen;
    return @peers<=16 && !grep {!GP_IPv4($_) || $seen{$_}++} @peers;
}

# GP_Field: Read a device internal with a fallback for missing devices or values.
sub GP_Field { return ($defs{$_[0] // ''} // {})->{$_[1]} // $_[2]; }

# GP_IsOpening: Identify actions that require the shared opening safety checks.
sub GP_IsOpening { return ($_[0]//'') =~ /\A(?:door_open|garage_open)\z/; }

# GP_LogPathValid: Validate a diagnostic log path before it is configured.
sub GP_LogPathValid {
    my ($path)=@_;
    return defined($path) && length($path)<=512 && $path =~ m{\A[A-Za-z0-9_./%+-]+\.(?:log|txt)\z}
        && $path !~ /%(?![YmdHM])/;
}

# GP_LogPath: Resolve the diagnostic log filename for the current local date.
sub GP_LogPath {
    my ($c)=@_;
    my $pattern=GP_Attr($c->{NAME},'logFile','');
    return '' unless GP_LogPathValid($pattern);
    return POSIX::strftime($pattern,localtime(GP_Now()));
}

# GP_DebugLogEnabled: Decide whether diagnostics are enabled for the controller and event mode.
# Logging is an output adapter, never a Reading update or FHEM event. The
# operating mode controls actions; debugLog independently controls diagnostics.
sub GP_DebugLogEnabled {
    my ($c,$detail)=@_;
    return 0 unless $c;
    my $setting=GP_Attr($c->{NAME},'debugLog','auto');
    return $setting eq '1' ? 1:0 unless $setting eq 'auto';
    $detail//={};
    my $mode=$detail->{mode}//(defined($detail->{resident}) ? GP_EffectiveMode($c,$detail->{resident},0)
        : GP_Mode($c->{NAME}));
    return $mode eq 'debug' || $mode eq 'learning' ? 1:0;
}

# GP_LogText: Decode, sanitize, and bound text written to operational logs.
sub GP_LogText {
    my ($text)=@_;
    $text//='';
    # FHEM's bytestream attributes contain UTF-8 bytes, while module literals
    # are characters. Decode before joining or removing Unicode controls.
    $text=decode('UTF-8',$text) if !$unicodeEncoding && !utf8::is_utf8($text);
    $text =~ s/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/ /g;
    return substr($text,0,512);
}

# GP_LogResident: Resolve a resident's human-readable name for log messages.
sub GP_LogResident {
    my ($r)=@_;
    my $rr=GP_Field($r,'ROOMMATE',$r);
    return GP_LogText(GP_Attr($r,'alias',GP_Attr($rr,'alias',$rr)));
}

# GP_NormalLog: Write a sanitized operational message through FHEM's logger.
# Only short, human-readable actions and operational warnings use FHEM's log.
sub GP_NormalLog {
    my ($c,$level,$text)=@_;
    return unless $c && defined &Log3;
    return if $level>GP_Attr($c->{NAME},'verbose',GP_Attr('global','verbose',3));
    my $line=$c->{NAME}.' GeoPresence: '.GP_LogText($text);
    GP_Profile($c,'normal_log',$c->{NAME},sub {Log3($c->{NAME},$level,$unicodeEncoding ? $line : encode('UTF-8',$line))});
}

# GP_LogAction: Translate selected productive decisions into concise operational messages.
sub GP_LogAction {
    my ($c,$r,$row)=@_;
    my $reason=$row->{reason}//'';
    my $who=GP_LogResident($r);
    my $target=GP_LogText(GP_Attr($row->{target}//'','alias',$row->{target}//''));
    my ($text,$level)=('',3);
    if ($reason eq 'zone observation processed' && $row->{changed}) {
        my $zone=GP_LogText($row->{zone_label}//$row->{zone});
        $text=($row->{entry} ? 'Entered area “' : 'Left area “').$zone.'”.';
    } elsif ($reason eq 'arrival confirmed' && $row->{changed} && ($row->{source}//'') eq 'phone_present') {
        $text='Arrived home (phone detected).';
    } elsif ($reason eq 'phone absence qualified' && $row->{changed}) {
        $text='Marked absent (phone absence confirmed).';
    } elsif ($reason eq 'notification dispatched' || $reason eq 'notification failed') {
        my %channels=(0=>'SmartHome',1=>'SmartHome',2=>'SmartAdmin',10=>'Pushover');
        my $channel=$channels{$row->{channel}//0}//'notification service';
        if ($reason eq 'notification dispatched') {
            $text='Notification handed to '.$channel.': “'.GP_LogText($row->{message}).'”.';
        } else { $text='Could not hand notification to '.$channel.'.'; $level=2; }
    } elsif ($reason eq 'switch command dispatched' || $reason eq 'switch command failed') {
        $text=($reason eq 'switch command dispatched' ? 'Switch-on requested for “' : 'Switch-on failed for “').$target.'”.';
        $level=2 if $reason eq 'switch command failed';
    } elsif ($reason eq 'actor command dispatched' || $reason eq 'actor command failed') {
        my $kind=($row->{kind}//'') eq 'door_open' ? 'Door opening' : 'Garage opening';
        $text=$reason eq 'actor command dispatched'
            ? $kind.' requested for “'.$target.'”.'
            : 'Could not request '.lcfirst($kind).' for “'.$target.'”.';
        $level=2 if $reason eq 'actor command failed';
    } elsif ($reason eq 'actor feedback') {
        my $door=($row->{kind}//'') eq 'door_open';
        if (($row->{result}//'') eq 'confirmed') {
            $text=$door ? 'Door opener “'.$target.'” confirmed the opening pulse.' : 'Garage “'.$target.'” is open.';
        } else {
            my %results=(failed=>'failed',cancelled=>'cancelled',uncertain=>'ended without confirmation');
            return unless exists $results{$row->{result}//''};
            $text=($door ? 'Door opening' : 'Garage opening').' for “'.$target.'” '.$results{$row->{result}}.'.';
            $level=2;
        }
    }
    GP_NormalLog($c,$level,$who.': '.$text) if length $text;
}

# GP_Log: Record operational notices and bounded, filtered file diagnostics.
# Structured diagnostics go exclusively to logFile, independent of verbose.
# Only selected fields enter it, never headers, bodies or credentials.
sub GP_Log {
    my ($c,$level,$event,$detail)=@_;
    return unless $c;
    if ($event eq 'listener_error') {
        GP_NormalLog($c,2,'Could not start webhook listener; check listener configuration.');
    } elsif ($event eq 'configuration_invalid' || $event eq 'configuration_ready') {
        GP_NormalLog($c,$level,GP_LogResident($detail->{resident}).': '
            .($event eq 'configuration_invalid' ? 'Invalid configuration; processing suspended.' : 'Configuration valid again.'));
    } elsif ($event eq 'geometry_applied') {
        GP_NormalLog($c,$level,GP_LogResident($detail->{resident}).': Location geometry confirmed for production; trips reset.');
    } elsif ($event eq 'roommate_status_failed') {
        GP_NormalLog($c,2,GP_LogResident($detail->{resident}).': Could not update ROOMMATE status.');
    } elsif ($event eq 'roommate_status_ready') {
        GP_NormalLog($c,3,GP_LogResident($detail->{resident}).': ROOMMATE status update accepted again.');
    }
    return unless GP_DebugLogEnabled($c,$detail);
    my $path=GP_LogPath($c);
    return unless length($path);
    my $rate=$c->{helper}{gp_log_rate}//={start=>GP_Mono(),count=>0};
    %$rate=(start=>GP_Mono(),count=>0) if GP_Mono()-$rate->{start}>=60 || GP_Mono()<$rate->{start};
    return if ++$rate->{count}>301;
    ($level,$event,$detail)=(2,'log_rate_limit',{reason=>'Further log entries suppressed for this minute'}) if $rate->{count}==301;
    my %safe;
    for my $key (qw(resident mode route isTest status reason field ignored_multiline phase rule kind target source zone observed received entry result changed motion motion_time wait_seconds deadline confirmation phone_state phone_health phone_latest home_exit departure_armed geometry_changes elapsed_ms cpu_ms start_lag_ms slowest_phase slowest_target slowest_self_ms started_at)) {
        next unless defined(($detail//{})->{$key}) && !ref($detail->{$key});
        $safe{$key}=substr($detail->{$key},0,512);
    }
    # ASCII JSON escapes embedded line breaks and Unicode separators as data.
    my $text=$c->{NAME}.' GeoPresence '.$event.' '.JSON::PP->new->canonical->ascii->encode(\%safe);
    my $error=GP_Profile($c,'diagnostic_file',$c->{NAME},sub {GP_WriteLog($path,$level,$text)});
    if ($error) {
        $c->{helper}{gp_log_error}=$error;
        if (!defined($c->{helper}{gp_log_warning}) || GP_Mono()-$c->{helper}{gp_log_warning}>=60
            || GP_Mono()<$c->{helper}{gp_log_warning}) {
            GP_NormalLog($c,1,'Could not write diagnostic log; check file path and permissions (get logStatus).');
            $c->{helper}{gp_log_warning}=GP_Mono();
        }
    } else { delete @{$c->{helper}}{qw(gp_log_error gp_log_warning)}; }
}

# GP_WriteLog: Append a UTF-8 diagnostic line and return any file error.
sub GP_WriteLog {
    my ($path,$level,$text)=@_;
    my $error;
    if (open my $fh,'>>:encoding(UTF-8)',$path) {
        my $ok=print {$fh} POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now()))." $level: $text\n";
        $error="Cannot write $path: $!" unless $ok;
        $error="Cannot close $path: $!" unless close $fh;
    } else { $error="Cannot open $path: $!"; }
    return $error;
}

# GP_LogDecision: Route a decision to operational and diagnostic logs for its mode.
sub GP_LogDecision {
    my ($c,$r,$row,$debug)=@_;
    my $level=$row->{diagnostic_only} ? 5 : 4;
    $level=3 if $row->{reason} =~ /\A(?:arrival confirmed|actor command dispatched|actor feedback|switch command dispatched|switch command failed)\z/;
    GP_LogAction($c,$r,$row) unless $debug;
    $level=3 if $row->{reason} eq 'qualified unfinished trip restored; waiting for a new return';
    GP_Log($c,$level,'decision',{%$row,resident=>$r,mode=>$debug ? 'debug':'active'});
}

# GP_LogTrace: Write only the unlogged tail of a resident's bounded trace.
sub GP_LogTrace {
    my ($c,$r,$s,$debug)=@_;
    my $trace=$s->{trace};
    return unless @$trace && ($trace->[-1]{sequence}//0)>($s->{log_sequence}//0);
    # Trace sequences increase monotonically, including after pruning old rows.
    # Only the unlogged tail matters; an idle timer must not revisit 1,000 rows.
    my $first=$#$trace;
    $first-- while $first>0 && ($trace->[$first-1]{sequence}//0)>($s->{log_sequence}//0);
    for my $index ($first..$#$trace) {
        my $row=$trace->[$index];
        next if $row->{sequence}<=($s->{log_sequence}//0);
        # Log3 subscribers may call back synchronously. Claim each row first.
        $s->{log_sequence}=$row->{sequence};
        GP_LogDecision($c,$r,$row,$debug);
    }
}

# GP_RecordAction: Record an actual adapter result even if a callback replaced its context.
sub GP_RecordAction {
    my ($c,$r,$s,$now,$reason,$detail)=@_;
    # Only actual output adapters and retained hardware reservations call here.
    # A callback may already have replaced the session: retain the real action
    # in both logs now, without restoring state or granting output permissions.
    if ($s) {
        GP_Trace($s,$now,$reason,$detail);
        GP_LogTrace($c,$r,$s,0);
    } else {
        GP_LogDecision($c,$r,{time=>$now,reason=>$reason,%{$detail//{}}},0);
    }
}

# GP_Reading: Return a Reading record or an empty fallback.
sub GP_Reading { return ((GP_Field($_[0], 'READINGS', {}))->{$_[1]} // {}); }

# GP_Read: Read a Reading value with a fallback when no value is defined.
sub GP_Read { return GP_Reading($_[0], $_[1])->{VAL} // $_[2]; }

# GP_Controller: Resolve the controller that owns a GeoPresence device.
sub GP_Controller {
    my ($d) = @_;
    return unless $d && ($d->{TYPE} // '') eq 'GeoPresence';
    return $d if ($d->{SUBTYPE} // '') eq 'controller';
    return $defs{$d->{CONTROLLER} // ''};
}

# GP_Residents: Return resident names from the controller's membership inventory.
sub GP_Residents {
    my ($c) = @_;
    return @{$c ? GP_Inventory($c)->{residents} : []};
}

# GP_DeviceNames: Return all GeoPresence device names belonging to the controller.
sub GP_DeviceNames {
    my ($c)=@_;
    return @{$c ? GP_Inventory($c)->{devices} : []};
}

# GP_Inventory: Build or reuse the controller's sorted device membership index.
# Membership is independent of attributes. Administrative callers must not
# compile adapters, rules or validation just to enumerate residents.
sub GP_Inventory {
    my ($c,$devices)=@_;
    return $c->{helper}{gp_devices} if $c->{helper}{gp_devices};
    my $inventory={devices=>[],residents=>[],members=>{},kinds=>{}};
    for my $name (sort($devices ? (map {$_->{NAME}} @$devices) : keys %defs)) {
        my $d=$defs{$name};
        next unless ($d->{TYPE}//'') eq 'GeoPresence' && ($d->{CONTROLLER}//'') eq $c->{NAME};
        push @{$inventory->{devices}},$name;
        $inventory->{members}{$name}=1;
        push @{$inventory->{kinds}{$d->{SUBTYPE}//''}},$name;
    }
    $c->{helper}{gp_work}{device_scans}++ if $c->{helper}{gp_work};
    $inventory->{residents}=$inventory->{kinds}{resident}//[];
    return $c->{helper}{gp_devices}=$inventory;
}

# GP_Dependencies: Build or reuse resident dependencies for configuration guards.
# This index is needed before an edit is committed to protect affected active
# residents. It contains references only, never executable adapter parameters.
sub GP_Dependencies {
    my ($c)=@_;
    my $inventory=GP_Inventory($c);
    return $inventory->{dependencies} if $inventory->{dependencies};
    my $index={dependents=>{},target_residents=>{}};
    for my $r (@{$inventory->{residents}}) {
        my $rr=$defs{$r}{ROOMMATE}//'';
        $index->{dependents}{$_}{$r}=1 for ($c->{NAME},$r,$rr,GP_List(GP_Attr($r,'phoneProxies','')));
        (my $suffix=$rr)=~s/^rr_//;
        $index->{dependents}{$_}{$r}=1 for ("People.Loc.$suffix","People.handler.$suffix.enter");
    }
    for my $n (@{$inventory->{kinds}{location}//[]}) {
        $index->{dependents}{$n}{$defs{$n}{PARENT}}=1;
    }
    my %references;
    for my $n (@{$inventory->{kinds}{action}//[]}) {
        my $type=$defs{$n}{ACTIONTYPE}//'';
        $references{$n}={map {$_=>GP_Attr($n,$_,'')} grep {
            /\A(?:target|contact|feedbackDevice|stateDevice|upperContact|lowerContact)\z/
        } @{$GP_ACTION_ATTRS{$type}//[]}};
    }
    for my $n (@{$inventory->{kinds}{rule}//[]}) {
        my $a=GP_Attr($n,'action','');
        my $refs=$references{$a}//{};
        my @names=($n,$a,GP_List(GP_Attr($n,'locations','')),grep {length} values %$refs);
        push @names,$1 if GP_Attr($n,'afterExit','') =~ /\Alocation:(.+)\z/;
        # Disabled rules still participate in administrative dependency guards.
        for my $r (GP_List(GP_Attr($n,'residents',''))) {
            $index->{dependents}{$_}{$r}=1 for @names;
            $index->{target_residents}{$refs->{target}}{$r}=1 if length($refs->{target}//'');
        }
    }
    for my $a (keys %references) {
        my $res=$index->{target_residents}{$references{$a}{target}//''}//{};
        $index->{dependents}{$a}{$_}=1 for keys %$res;
    }
    return $inventory->{dependencies}=$index;
}

# GP_Catalog: Prepare shared rules, adapters, identities, and static validation inputs.
# Configuration is immutable between configuration changes. Runtime readings,
# transport availability and geometry observation times do not belong here.
sub GP_Catalog {
    my ($c)=@_;
    return $c->{helper}{gp_config} if $c->{helper}{gp_config};
    my $inventory=GP_Inventory($c);
    my $catalog={%{GP_Dependencies($c)},actions=>{},rules=>{},locations=>{},users=>{},common_errors=>[],
        rule_errors=>{},target_errors=>{},config=>{},views=>{},errors=>{}};
    push @{$catalog->{common_errors}},"$_: invalid GeoPresence device name"
        for grep {!GP_Name($_)} @{$inventory->{devices}};
    my (%devices,%users,%roommates,%signatures);
    for my $r (@{$inventory->{residents}}) {
        my $rr=$defs{$r}{ROOMMATE}//'';
        push @{$catalog->{common_errors}},"Duplicate ROOMMATE for $r" if $roommates{$rr}++;
        next unless GP_UsesSource(GP_Attr($r,'sourceMode','geofency_phone'),'geo');
        for my $spec ([deviceId=>\%devices],[webhookUser=>\%users]) {
            my $v=lc GP_Attr($r,$spec->[0],'');
            push @{$catalog->{common_errors}},"Duplicate $spec->[0] for $r" if length($v) && $spec->[1]{$v}++;
        }
        push @{$catalog->{users}{GP_Attr($r,'webhookUser','')}},$r;
    }
    for my $n (@{$inventory->{kinds}{location}//[]}) {
        my $r=$defs{$n}{PARENT};
        push @{$catalog->{locations}{$r}},$n;
    }
    for my $n (@{$inventory->{kinds}{action}//[]}) {
        my $type=$defs{$n}{ACTIONTYPE}//'';
        my $params={map {$_=>$attr{$n}{$_}} grep {exists $attr{$n}{$_}} @{$GP_ACTION_ATTRS{$type}//[]}};
        my $action=$catalog->{actions}{$n}={name=>$n,type=>$type,params=>$params};
        $action->{errors}=[GP_ValidateAction($action)];
        next if $type eq 'notify' || !length($params->{target}//'');
        my $target=$params->{target};
        my $signature=$GP_JSON->encode({type=>$type,params=>{%$params,
            (GP_IsOpening($type) ? (positionSignalMode=>$params->{positionSignalMode}//'state'):())}});
        $catalog->{target_errors}{$target}="Conflicting action definitions for $target"
            if exists($signatures{$target}) && $signatures{$target} ne $signature;
        $signatures{$target}=$signature;
    }
    for my $n (@{$inventory->{kinds}{rule}//[]}) {
        my @res=GP_List(GP_Attr($n,'residents',''));
        my $a=GP_Attr($n,'action','');
        my $action=$catalog->{actions}{$a}//{type=>'',params=>{}};
        next unless GP_Attr($n,'enabled',1);
        my @errors; my %seen;
        push @errors,"$n: residents required" unless @res;
        for my $r (@res) {
            push @errors,"$n: unknown resident $r" unless GP_Field($r,'TYPE','') eq 'GeoPresence' && GP_Field($r,'SUBTYPE','') eq 'resident'
                && GP_Field($r,'CONTROLLER','') eq $c->{NAME};
            push @errors,"$n: duplicate resident $r" if $seen{$r}++;
        }
        $catalog->{rule_errors}{$n}=\@errors;
        my $rule={name=>$n,trigger=>GP_Attr($n,'trigger',''),group=>GP_Attr($n,'locationGroup',''),
            locations=>[GP_List(GP_Attr($n,'locations',''))],afterExit=>GP_Attr($n,'afterExit',''),
            arrivalFilter=>GP_Attr($n,'arrivalFilter','any'),cooldown=>0+GP_Attr($n,'cooldown',300),
            action=>$a,type=>$action->{type},params=>$action->{params}};
        push @{$catalog->{rules}{$_}},$rule for sort keys %seen;
    }
    my $transport_error=GP_HTTPConfigError($c);
    push @{$catalog->{common_errors}},$transport_error if $transport_error;
    push @{$catalog->{common_errors}},'reorder_window must be smaller than action_max_age'
        if GP_Attr($c->{NAME},'reorder_window',$GP_DEFAULT{reorder_window})
            >=GP_Attr($c->{NAME},'action_max_age',$GP_DEFAULT{action_max_age});
    push @{$catalog->{common_errors}},"$c->{NAME}: remove obsolete attribute $_; use set mode"
        for grep {exists $attr{$c->{NAME}}{$_}} qw(mode operatingMode);
    # Retain the published bindings while a shared cache is cold. A change to
    # another resident must not revoke this resident's in-flight plans.
    $c->{helper}{gp_output_dependencies}=$catalog->{dependents};
    return $c->{helper}{gp_config}=$catalog;
}

# GP_InvalidateConfig: Invalidate prepared configuration or a selected resident view.
sub GP_InvalidateConfig {
    my ($c,$r,$debug)=@_;
    return unless $c;
    unless (defined $r) {
        delete $c->{helper}{gp_config};
        delete $c->{helper}{gp_devices}{dependencies} if $c->{helper}{gp_devices};
        return;
    }
    my $catalog=$c->{helper}{gp_config} or return;
    delete $catalog->{views}{$_}{$r} for defined($debug) ? ($debug?'debug':'prod') : qw(prod debug);
}

# GP_InvalidateDevices: Discard the membership inventory and its derived configuration.
sub GP_InvalidateDevices {
    my ($c)=@_;
    return unless $c;
    delete $c->{helper}{gp_devices};
    GP_InvalidateConfig($c);
}

# GP_Mode: Read a supported stored mode, falling back to disabled.
sub GP_Mode {
    my ($name)=@_;
    my $value=GP_Read($name,'mode','disabled');
    return $value if $value =~ /\A(?:active|debug|disabled)\z/;
    return 'learning' if $value eq 'learning' && GP_Field($name,'SUBTYPE','') eq 'resident';
    return 'disabled';
}

# GP_StoreMode: Store an operating mode without Reading events or user callbacks.
sub GP_StoreMode {
    my ($d,$mode)=@_;
    # Operator state belongs in fhem.save, not in a second configuration attr.
    # No userReadings/stateFormat callbacks or action events during a transition.
    setReadingsVal($d,'mode',$mode,POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now())));
}

# GP_EffectiveMode: Combine controller, resident, and test modes into the effective mode.
sub GP_EffectiveMode {
    my ($c,$r,$test)=@_;
    my $cm=GP_Mode($c->{NAME}); my $rm=GP_Mode($r);
    return 'disabled' if $cm eq 'disabled' || $rm eq 'disabled';
    return 'learning' if $rm eq 'learning';
    return 'debug' if $test || $cm eq 'debug' || $rm eq 'debug';
    return 'active';
}

# GP_ModeReason: Explain how controller and resident modes determine current behavior.
sub GP_ModeReason {
    my ($c,$r)=@_;
    return 'Controller is disabled' if GP_Mode($c->{NAME}) eq 'disabled';
    return 'Resident is disabled' if GP_Mode($r) eq 'disabled';
    return 'Resident is learning; observations only' if GP_Mode($r) eq 'learning';
    return 'Controller is in debug mode' if GP_Mode($c->{NAME}) eq 'debug';
    return 'Resident is in debug mode' if GP_Mode($r) eq 'debug';
    return 'Controller and resident are active';
}

# GP_UpdateModes: Refresh resident mode displays without emitting events.
sub GP_UpdateModes {
    my ($c)=@_;
    for my $r (GP_Residents($c)) {
        my %values=(effectiveMode=>GP_EffectiveMode($c,$r,0),modeReason=>GP_ModeReason($c,$r));
        # STATE is the FHEM device display, not the resident's presence or a new
        # control reading. Refresh it even when restored mode readings match.
        $defs{$r}{STATE}=$values{effectiveMode};
        for my $key (keys %values) {
            next if GP_Read($r,$key,'') eq $values{$key};
            setReadingsVal($defs{$r},$key,$values{$key},POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now())));
        }
    }
}

# GP_AffectedResidents: Identify residents affected by a device or proposed reference change.
sub GP_AffectedResidents {
    my ($c,$d,$change)=@_;
    my $kind=$d->{SUBTYPE}//''; my $name=$d->{NAME};
    return GP_Residents($c) if $kind eq 'controller';
    return ($name) if $kind eq 'resident';
    my $index=GP_Dependencies($c);
    my %res=%{$index->{dependents}{$name}//{}};
    $res{$d->{PARENT}}=1 if $kind eq 'location';
    if ($kind eq 'rule') {
        $res{$_}=1 for GP_List(GP_Attr($name,'residents',''));
        $res{$_}=1 for GP_List($change->{residents}//'');
    }
    if ($kind eq 'action') {
        for my $target (grep {length} (GP_Attr($name,'target',''),$change->{target}//'')) {
            $res{$_}=1 for keys %{$index->{target_residents}{$target}//{}};
        }
    }
    return sort grep {GP_Field($_,'SUBTYPE','') eq 'resident' && GP_Field($_,'CONTROLLER','') eq $c->{NAME}} keys %res;
}

# GP_ConfigChangeError: Reject configuration edits that affect active residents or an active controller.
sub GP_ConfigChangeError {
    my ($c,$d,$change)=@_;
    return unless $c && $init_done;
    return 'Controller configuration requires set '.$c->{NAME}.' mode debug or disabled'
        if ($d->{SUBTYPE}//'') eq 'controller' && GP_Mode($c->{NAME}) eq 'active';
    my @active=grep {GP_EffectiveMode($c,$_,0) eq 'active'} GP_AffectedResidents($c,$d,$change//{});
    return 'Configuration affects active residents: '.join(', ',@active).'; use set RESIDENT mode debug or disabled first' if @active;
    return;
}

# GP_ConfigChanged: Reset affected contexts and defer rebuilding the committed configuration.
sub GP_ConfigChanged {
    my ($c,$d,$change)=@_;
    return unless $c;
    # INITIALIZED/REREADCFG resets the complete restored session once. Loading
    # individual lines needs no intermediate dependency or mode rebuilding.
    unless ($init_done) { GP_InvalidateConfig($c); return; }
    return GP_ResetController($c) if ($d->{SUBTYPE}//'') eq 'controller';
    my @affected=GP_AffectedResidents($c,$d,$change//{});
    GP_ResetResident($c,$_) for @affected;
    GP_UpdateModes($c);
    # AttrFn has not committed its value yet. Publish the next catalogue only
    # when a later caller reads the committed definitions and attributes.
    GP_InvalidateConfig($c);
}

# GeoPresence_Define: Validate a new device definition or change an existing location's role.
sub GeoPresence_Define {
    my ($hash, $def) = @_;
    my ($name, $type, $kind, @args) = split /\s+/, $def;
    return 'Usage: define name GeoPresence controller|resident|location|action|rule ...'
        unless GP_Name($name) && exists $GP_ATTRS{$kind // ''};
    if ($hash->{SUBTYPE}) {
        return 'Only the function of an existing location can be modified'
            unless $kind eq 'location' && $hash->{SUBTYPE} eq 'location' && @args==2 && $args[0] eq $hash->{PARENT};
        my $c=GP_Controller($hash);
        my $error=GP_ConfigChangeError($c,$hash); return $error if $error;
        return 'Invalid location function; choose home, outer, approach or place'
            unless $args[1] =~ /\A(?:home|outer|approach|place)\z/;
        $hash->{ROLE}=$args[1];
        GP_ConfigChanged($c,$hash);
        return;
    }
    return 'Only one GeoPresence controller is supported' if $kind eq 'controller'
        && grep {($_->{TYPE}//'') eq 'GeoPresence' && ($_->{SUBTYPE}//'') eq 'controller'} values %defs;
    my %count = (controller => 0, resident => 2, location => 2, action => 2, rule => 1);
    return "Wrong argument count for $kind" unless @args == $count{$kind};
    if ($kind ne 'controller') {
        my $parent = $defs{$args[0]};
        my $expected = $kind eq 'location' ? 'resident' : 'controller';
        return "Missing $expected device $args[0]" unless $parent
            && ($parent->{TYPE} // '') eq 'GeoPresence' && ($parent->{SUBTYPE} // '') eq $expected;
        my $c = GP_Controller($parent);
        my $error=GP_ConfigChangeError($c,{NAME=>$name,SUBTYPE=>$kind,PARENT=>$args[0]});
        return $error if $error;
        $hash->{CONTROLLER} = $c->{NAME};
        $hash->{PARENT} = $args[0];
    }
    if ($kind eq 'resident') {
        return 'Resident must reference an existing ROOMMATE' unless GP_Name($args[1])
            && GP_Field($args[1], 'TYPE', '') eq 'ROOMMATE';
        return 'ROOMMATE already belongs to another GeoPresence resident'
            if grep {GP_Field($_,'ROOMMATE','') eq $args[1]} GP_Residents(GP_Controller($hash));
        $hash->{ROOMMATE} = $args[1];
    } elsif ($kind eq 'location') {
        return 'Invalid location function; choose home, outer, approach or place' unless $args[1] =~ /\A(?:home|approach|outer|place)\z/;
        $hash->{ROLE} = $args[1];
    } elsif ($kind eq 'action') {
        return 'Invalid action type' unless $args[1] =~ /\A(?:door_open|garage_open|notify|switch_on)\z/;
        $hash->{ACTIONTYPE} = $args[1];
    }
    $hash->{SUBTYPE} = $kind;
    $hash->{NOTIFYDEV} = $kind eq 'controller' ? 'global' : '';
    $hash->{STATE} = $kind eq 'controller' || $kind eq 'resident' ? 'disabled' : 'configured';
    # During startup/rereadcfg the state file is loaded AFTER the definitions.
    # A fresh timestamp here would make FHEM discard the older saved mode.
    # GP_Mode supplies disabled until restoration; initialize missing readings
    # only after INITIALIZED/REREADCFG. Interactive defines default immediately.
    GP_StoreMode($hash,'disabled') if $init_done && ($kind eq 'controller' || $kind eq 'resident');
    if ($kind eq 'controller') {
        $hash->{CONTROLLER} = $name;
        GP_InvalidateDevices($hash);
        GP_ResetController($hash);
    } else {
        my $c=GP_Controller($hash);
        GP_InvalidateDevices($c);
        GP_ConfigChanged($c,$hash);
    }
    GP_UpdateAttrLists($hash);
    return;
}

# GP_ResetController: Start a new controller session while retaining active actor reservations.
sub GP_ResetController {
    my ($c,$policy) = @_;
    $policy//='invalidate';
    return unless $c;
    my $previous=$c->{helper}{gp}//{};
    if ($policy eq 'resume' && $init_done) {
        # Capture a live qualified trip when updating from a version which did
        # not yet publish checkpoints. Never preserve a queued output adapter.
        for my $r (keys %{$previous->{prod}//{}}) {
            GP_Checkpoint($c,$r,undef,$previous->{prod}{$r});
        }
    } elsif ($init_done) {
        GP_ClearCheckpoint($_,'Controller configuration changed') for GP_Residents($c);
    }
    GP_StopHTTP($c);
    # A reload must also remove the old FHEMWEB registration. This cannot make
    # that FHEMWEB server safe: the operator must remove it and retarget the proxy.
    for my $path (keys %{$data{FWEXT} // {}}) {
        delete $data{FWEXT}{$path} if ($data{FWEXT}{$path}{GP_OWNER} // '') eq $c->{NAME};
    }
    RemoveInternalTimer($c, 'GeoPresence_Timer') if defined &RemoveInternalTimer;
    my $old = $c->{helper}{gp} // {};
    GP_StoreMode($defs{$_},'disabled') for grep {GP_Mode($_) eq 'learning'} GP_Residents($c);
    delete $GP_AUTH{$_} for GP_Residents($c);
    # Retain observation of already dispatched hardware, never pending intentions.
    # Learning results are manual setup data, not a live reception window or trip.
    # An unconfirmed phone identity must not survive a reset of its authorizing
    # session (including password/configuration changes and module reloads).
    my %learned=map {$_=>$old->{learned}{$_}}
        grep {$old->{learned}{$_}{confirmed}} keys %{$old->{learned}//{}};
    $c->{helper}{gp} = { start => GP_Now(), mono => GP_Mono(), epoch => ($old->{epoch} // 0)+1,
        prod => {}, debug => {}, actors => $old->{actors} // {}, queue => [], ready => 0,
        learned => \%learned,
        resume_pending => $policy eq 'resume' ? {map {$_=>1} GP_Residents($c)} : {} };
    GP_Log($c,3,'session_reset',{reason=>$policy eq 'resume'
        ? 'New session; saved qualified trips await validation; pending actions discarded'
        : 'New session; opening permissions revoked'});
    GP_UpdateModes($c);
    GP_InvalidateConfig($c);
    GP_ScheduleTimer($c,0.1) if defined &InternalTimer;
}

# GP_ResetResident: Discard a resident's runtime contexts and reset its session metadata.
sub GP_ResetResident {
    my ($c,$r,$keep)=@_; $keep//='';
    my $rt=$c->{helper}{gp} or return;
    GP_ClearCheckpoint($r,'Resident mode or configuration changed') if $init_done;
    delete $rt->{resume_pending}{$r};
    delete $rt->{prod}{$r}; delete $rt->{debug}{$r};
    delete $rt->{geometry}{debug}{$r}; delete $rt->{geometry}{prod}{$r};
    delete $rt->{geometry_dirty}{$r};
    GP_InvalidateConfig($c,$r);
    delete $rt->{learning}{$r} unless $keep eq 'learning';
    delete $rt->{learned}{$r} if !$keep && !($rt->{learned}{$r}//{})->{confirmed};
    GP_StoreMode($defs{$r},'disabled') if $keep ne 'learning' && GP_Mode($r) eq 'learning';
    delete $rt->{errors}{$r};
    @{$rt->{queue}}=grep {$_->{resident} ne $r} @{$rt->{queue}};
    # An old name must not leave session clocks or counters for a later device to inherit.
    if (exists $defs{$r}) {
        $rt->{resident_start}{$r}=GP_Now();
        $rt->{resident_mono}{$r}=GP_Mono();
        $rt->{resident_generation}{$r}++;
    } else {
        delete $rt->{$_}{$r} for qw(resident_start resident_mono resident_generation);
    }
}

# GeoPresence_Undef: Guard device removal and release or invalidate its owned runtime resources.
sub GeoPresence_Undef {
    my ($hash) = @_;
    my $c = GP_Controller($hash);
    if (($hash->{SUBTYPE} // '') eq 'controller') {
        RemoveInternalTimer($hash, 'GeoPresence_Timer');
        GP_StopHTTP($hash);
        for my $path (keys %{$data{FWEXT} // {}}) {
            delete $data{FWEXT}{$path} if ($data{FWEXT}{$path}{GP_OWNER} // '') eq $hash->{NAME};
        }
        delete $hash->{helper}{gp};
        GP_InvalidateDevices($hash);
        delete $hash->{helper}{gp_timer_due};
    } else {
        my $error=GP_ConfigChangeError($c,$hash); return $error if $error;
        if ($c && ($hash->{SUBTYPE}//'') eq 'resident') {
            delete $c->{helper}{gp}{learned}{$hash->{NAME}};
            delete $c->{helper}{gp}{http_rate}{$hash->{NAME}};
        }
        GP_ConfigChanged($c,$hash);
        GP_InvalidateDevices($c);
    }
    return;
}

# GeoPresence_Delete: Remove a deleted resident's cached and stored webhook credentials.
sub GeoPresence_Delete {
    my ($hash) = @_;
    return unless ($hash->{SUBTYPE} // '') eq 'resident';
    delete $GP_AUTH{$hash->{NAME}};
    return GP_StoreAuth($hash->{NAME},undef);
}

# GeoPresence_Rename: Repair internal bindings and revoke affected plans after a FHEM rename.
sub GeoPresence_Rename {
    my ($new,$old)=@_;
    my $d=$defs{$new} or return;
    my $c=GP_Controller($d) or return;
    my $kind=$d->{SUBTYPE};my $rt=$c->{helper}{gp};
    my $owner=$kind eq 'controller' ? $old:$c->{NAME};
    my $inventory=$c->{helper}{gp_devices};
    # FHEM already moved the device; cached membership may still contain its old name.
    my @devices=$inventory
        ? grep {defined} map {$defs{$_ eq $old ? $new:$_}} @{$inventory->{devices}}
        : grep {($_->{TYPE}//'') eq 'GeoPresence' && ($_->{CONTROLLER}//'') eq $owner} values %defs;
    my %affected=$kind eq 'controller' ? () : map {$_=>1} keys %{($c->{helper}{gp_output_dependencies}//{})->{$old}//{}};
    $affected{$old}=$affected{$new}=1 if $kind eq 'resident';
    $affected{$d->{PARENT}}=1 if $kind eq 'location';
    for my $child (@devices) {
        $child->{CONTROLLER}=$new if $kind eq 'controller';
        if (($child->{PARENT}//'') eq $old) {
            $child->{PARENT}=$new;
            $child->{DEF} =~ s/\A(\w+\s+)\Q$old\E(?=\s|\z)/$1$new/ if defined $child->{DEF};
        }
        # Public rule attributes are not silently rewritten. Revoke every
        # resident of a shared rule when its resident selector becomes stale.
        next unless ($child->{SUBTYPE}//'') eq 'rule' && $kind =~ /\A(?:resident|action|rule)\z/;
        # Resident renames need the selector itself; other renames can filter rules first.
        next if ($kind eq 'rule' && $child!=$d)
            || ($kind eq 'action' && GP_Attr($child->{NAME},'action','') ne $old);
        my @res=GP_List(GP_Attr($child->{NAME},'residents',''));
        next if $kind eq 'resident' && !grep {$_ eq $old} @res;
        $affected{$_}=1 for @res;
    }
    my $auth_error;
    if ($kind eq 'resident') {
        for my $r (keys %affected) {
            GP_RevokeOutputs($rt->{$_}{$r}) for grep {$rt && $rt->{$_}{$r}} qw(prod debug);
        }
        # The callback runs after FHEM moved the device. Never revive old plans
        # or trust a leftover key belonging to a previous use of the new name.
        my ($error,$secret)=GP_ReadAuth($old);
        $error=GP_StoreAuth($new,$secret) unless $error;
        $error=GP_StoreAuth($old,undef) unless $error;
        delete @GP_AUTH{$old,$new};
        if ($error) {
            setReadingsVal($d,'gp_auth_error','Could not migrate credentials; set webhookPassword again',
                POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now())));
            GP_StoreMode($d,'disabled') if GP_UsesSource(GP_Attr($new,'sourceMode','geofency_phone'),'geo');
            $auth_error=1;
        }
        if ($rt) {
            GP_ResetResident($c,$old);
            for my $key (qw(learned http_rate)) {
                $rt->{$key}{$new}=delete $rt->{$key}{$old} if exists $rt->{$key}{$old};
            }
            for my $actor (values %{$rt->{actors}}) {
                $actor->{waiters}{$new}=delete $actor->{waiters}{$old} if exists $actor->{waiters}{$old};
            }
        }
    }
    # The old socket and clients are closed by ResetController. A later timer
    # binds the new owner; already dispatched actors remain observed.
    GP_InvalidateDevices($c);
    GP_Inventory($c,\@devices);
    if ($kind eq 'controller') {
        GP_ResetController($c);
    } else {
        GP_ResetResident($c,$_) for grep {GP_Field($_,'SUBTYPE','') eq 'resident'
            && GP_Field($_,'CONTROLLER','') eq $c->{NAME}} keys %affected;
        GP_UpdateModes($c);
        GP_UpdateNotifyDevices($c) if $rt;
    }
    GP_NormalLog($c,2,$new.': Could not migrate webhook credentials after rename; set webhookPassword again.') if $auth_error;
    return;
}

# GeoPresence_Attr: Validate attribute edits before FHEM commits them and invalidate affected state.
sub GeoPresence_Attr {
    my ($cmd, $name, $key, $value) = @_;
    $key//=''; # FHEM omits the key when deleteattr removes all attributes.
    my $d = $defs{$name} or return;
    return $cmd eq 'del' ? undef : 'Use set '.$name.' mode active|debug|disabled; mode attributes are not supported'
        if $key eq 'mode' || $key eq 'operatingMode';
    return 'Geometry is received from Geofency; do not configure coordinates or radius'
        if $cmd eq 'set' && ($d->{SUBTYPE}//'') eq 'location' && $key =~ /\A(?:latitude|longitude|radius)\z/;
    my $kind = $d->{SUBTYPE};
    return "Attribute $key is not valid for $kind" if $GP_ALLOWED{$key}
        && !grep { $_ eq $key } @{$GP_ATTRS{$kind}};
    my @keys=GP_ConfigAttrKeys($d,$key,$cmd eq 'del');
    return unless @keys || $key eq 'debugLog' || $key eq 'logFile';
    return "Attribute $key is not used by the selected sourceMode" if $cmd eq 'set' && $init_done
        && $kind eq 'resident' && !GP_ResidentAttrEnabled(GP_Attr($name,'sourceMode','geofency_phone'),$key);
    return "Attribute $key is not used by the selected trigger or location selector" if $cmd eq 'set' && $init_done
        && $kind eq 'rule' && !GP_RuleAttrEnabled($name,$key);
    return "Attribute $key is not valid for $d->{ACTIONTYPE}" if $cmd eq 'set' && $init_done
        && $kind eq 'action' && !grep {$_ eq $key} @{$GP_ACTION_ATTRS{$d->{ACTIONTYPE}}};
    my $c = GP_Controller($d);
    # Diagnostic settings must not end an active learning window or trip.
    if ($key eq 'debugLog') {
        return 'debugLog must be auto, 0 or 1' if $cmd eq 'set' && (!defined($value) || $value !~ /\A(?:auto|0|1)\z/);
        return;
    }
    if ($key eq 'logFile') {
        return 'logFile needs a text filename; allowed date patterns: %Y %m %d %H %M'
            if $cmd eq 'set' && !GP_LogPathValid($value);
        delete @{$c->{helper}}{qw(gp_log_error gp_log_warning)};
        return;
    }
    my $change={map {$_=>$cmd eq 'set' ? $value:undef} @keys};
    my $error=GP_ConfigChangeError($c,$d,$change); return $error if $error;
    if ($cmd eq 'set') {
        return 'Invalid control character or command separator' if !defined($value) || $value =~ /[\r\n\x00;]/;
        return "Invalid value for $key" if $GP_ENUMS{$key} && !grep {$_ eq $value} @{$GP_ENUMS{$key}};
        if ($key eq 'command' && ($d->{ACTIONTYPE}//'') ne 'notify') {
            my $expected=$d->{ACTIONTYPE} eq 'door_open' ? 'lock unlocked':'on';
            return "command must be $expected" if $value ne $expected;
        }
        return "Invalid positive value for $key" if exists $GP_DEFAULT{$key}
            && (!GP_Number($value) || $value <= 0 || $value > 172800);
        return "$key must not exceed 300 seconds" if $key =~ /\Aarrival_(?:wait_\w+|motion_max_age)\z/ && $value>300;
        return 'Invalid cooldown' if $key eq 'cooldown' && ($value !~ /\A\d+\z/ || $value > 86400);
        return 'Invalid UUID or identifier' if $key =~ /\A(?:deviceId|zoneId|webhookUser)\z/ && !GP_Id($value);
        return 'locationGroup must be a name of 1..64 letters, digits, dots, underscores or hyphens, starting with a letter'
            if $key eq 'locationGroup' && !GP_Group($value);
        if ($key eq 'groups') {
            my @groups=GP_List($value); my %seen;
            return 'groups must list 1..16 distinct group names, separated by commas without spaces'
                unless @groups && @groups<=16 && join(',',@groups) eq $value
                    && !grep {!GP_Group($_) || $seen{$_}++} @groups;
        }
        return 'afterExit must be location:DEVICE or group:GROUP; delete the attribute for no prerequisite'
            if $key eq 'afterExit' && $value !~ /\A(?:location:[A-Za-z][A-Za-z0-9_.-]*|group:[A-Za-z][A-Za-z0-9_.-]{0,63})\z/;
        return 'webhookPath must be a simple path component' if $key eq 'webhookPath' && $value !~ /\A[a-zA-Z][a-zA-Z0-9_-]*\z/;
        return 'webhookPort must be an integer from 1024 to 65535' if $key eq 'webhookPort'
            && ($value !~ /\A[0-9]{4,5}\z/ || $value < 1024 || $value > 65535);
        return 'webhookBindAddress must be a concrete IPv4 address; no wildcard or hostname'
            if $key eq 'webhookBindAddress' && !GP_IPv4($value);
        return 'webhookAllowedPeers must list 1..16 distinct IPv4 addresses separated by commas'
            if $key eq 'webhookAllowedPeers' && !GP_PeerListValid($value);
        if ($kind eq 'resident' && $key =~ /\A(?:deviceId|webhookUser)\z/) {
            return "$key already belongs to another resident" if grep {$_ ne $name && lc GP_Attr($_,$key,'') eq lc($value)} GP_Residents($c);
        }
    }
    if ($init_done && (exists($change->{reorder_window}) || exists($change->{action_max_age}))) {
        # Loading applies attributes one at a time, possibly in sorted order.
        # Validate their relationship only once that complete configuration is
        # available. Interactive edits still validate the proposed pair here.
        my $window=exists($change->{reorder_window}) ? $change->{reorder_window}//$GP_DEFAULT{reorder_window}
            : GP_Attr($name,'reorder_window',$GP_DEFAULT{reorder_window});
        my $age=exists($change->{action_max_age}) ? $change->{action_max_age}//$GP_DEFAULT{action_max_age}
            : GP_Attr($name,'action_max_age',$GP_DEFAULT{action_max_age});
        return 'reorder_window must be smaller than action_max_age' if $window >= $age;
    }
    # Results belong to this phone identity. Returning to an old ID must not
    # revive a previous phone's setup data; same-ID spelling changes are harmless.
    delete $c->{helper}{gp}{learned}{$name} if grep {
        exists($change->{$_}) && ($cmd ne 'set' || lc($value) ne lc GP_Attr($name,$_ ,''))
    } qw(deviceId sourceMode webhookUser);
    # AttrFn runs before FHEM commits the attribute. Rebuild on the next tick.
    GP_ConfigChanged($c,$d,$change);
    if (grep {exists($change->{$_})} qw(sourceMode trigger locations locationGroup groups)) {
        local @{$attr{$name}}{@keys}=@{$change}{@keys};
        GP_UpdateAttrLists();
    }
    return;
}

# GP_Distance: Calculate the great-circle distance between two positions in meters.
sub GP_Distance {
    my ($a, $b) = @_;
    my $rad = 3.141592653589793 / 180;
    my $p = sin(($b->{lat}-$a->{lat})*$rad/2)**2
        + cos($a->{lat}*$rad)*cos($b->{lat}*$rad)*sin(($b->{lon}-$a->{lon})*$rad/2)**2;
    $p = 1 if $p > 1;
    return 6371000 * 2 * atan2(sqrt($p), sqrt(1-$p));
}

# GP_HasGeometry: Check that a circle has valid coordinates and a supported radius.
sub GP_HasGeometry {
    my ($g)=@_;
    return $g && GP_Number($g->{lat}) && abs($g->{lat})<=90
        && GP_Number($g->{lon}) && abs($g->{lon})<=180
        && GP_Number($g->{radius}) && $g->{radius}>0 && $g->{radius}<=100000;
}

# GP_MissingGeometry: List configured Geo locations that still lack valid geometry.
sub GP_MissingGeometry {
    my ($cfg)=@_;
    return () unless GP_UsesSource($cfg->{sourceMode},'geo');
    return grep {!GP_HasGeometry($cfg->{zones}{$_})} sort keys %{$cfg->{zones}};
}

# GP_ValidGeometryRecord: Validate saved geometry against the resident and location identities.
sub GP_ValidGeometryRecord {
    my ($g,$r,$zone)=@_;
    return ref($g) eq 'HASH' && GP_HasGeometry($g)
        && ($g->{device}//'') eq lc GP_Attr($r,'deviceId','')
        && ($g->{id}//'') eq lc GP_Attr($zone,'zoneId','')
        && GP_Number($g->{time}) && $g->{time}>0
        && GP_Number($g->{changed}) && $g->{changed}>0 && $g->{changed}<=$g->{time};
}

# GP_Geometry: Load or reuse geometry in the selected production or debug pool.
sub GP_Geometry {
    my ($c,$r,$zone,$debug)=@_;
    my $pool=$debug ? 'debug':'prod';
    my $cache=$c->{helper}{gp}{geometry}{$pool}{$r}//={};
    return $cache->{$zone} if exists $cache->{$zone};
    # Debug starts with a COPY of saved metadata, never with productive runtime
    # observations. It never writes these readings or transfers simulated data.
    my $g=eval {$GP_JSON->decode(GP_Read($zone,'gp_geometry','{}'))};
    $g={} unless GP_ValidGeometryRecord($g,$r,$zone);
    # Reviewed enrollment metadata can prepare a newly defined location without
    # another simulated visit. Only explicit applyGeometry writes it to readings.
    my $learned=GP_Learned($c,$r);
    my $captured=$learned && $learned->{confirmed} ? $learned->{zones}{lc GP_Attr($zone,'zoneId','')}:undef;
    if ($debug && $captured && GP_HasGeometry($captured->{geometry}) && $captured->{time}>=($g->{time}//0)) {
        $g={%{$captured->{geometry}},time=>$captured->{time},changed=>$captured->{time},
            device=>$learned->{device},id=>$captured->{id},blocked=>0};
    }
    return $cache->{$zone}=$g;
}

# GP_GeometryErrors: Report missing, conflicting, or incorrectly nested technical circles.
sub GP_GeometryErrors {
    my ($cfg)=@_;
    return () if $cfg->{sourceMode} eq 'phone_only';
    my @errors;
    for my $role (qw(home outer)) {
        push @errors,"$role location not registered" unless @{$cfg->{roles}{$role}//[]}==1;
    }
    for my $role (qw(home outer approach)) {
        for my $n (@{$cfg->{roles}{$role}//[]}) {
            push @errors,"$n: geometry awaiting Geofency webhook" unless GP_HasGeometry($cfg->{zones}{$n});
        }
    }
    for my $z (values %{$cfg->{zones}}) {
        push @errors,"$z->{name}: conflicting geometry timestamp; waiting for newer webhook" if $z->{blocked};
    }
    for my $pair ([qw(home outer)],[qw(home approach)],[qw(approach outer)]) {
        my ($small)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{$pair->[0]}//[]};
        my ($large)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{$pair->[1]}//[]};
        next unless GP_HasGeometry($small) && GP_HasGeometry($large);
        push @errors,"$pair->[0] is not contained in $pair->[1]"
            if GP_Distance($small,$large)+$small->{radius}>$large->{radius};
    }
    return @errors;
}

# GP_RevokeGeometry: Clear travel permissions and pending outputs after a geometry change.
sub GP_RevokeGeometry {
    my ($s,$time,$now)=@_;
    delete @{$s}{qw(trip arrival approach automotive motion motion_time desired_status conflict)};
    $s->{zones}={}; $s->{members}={}; GP_RevokeOutputs($s); $s->{queued_phones}=[];
    $s->{phase}='unknown'; $s->{location}='unknown';
    $s->{position_time}=$time if $time>($s->{position_time}//0);
    GP_ResetNegative($s,$time);
    GP_Trace($s,$now,'geometry learned or changed; trip and pending actions revoked');
}

# GP_UpdateGeometry: Accept fresh geometry and report whether it changed, conflicted, or stayed unchanged.
sub GP_UpdateGeometry {
    my ($c,$r,$debug,$s,$e,$cfg,$now)=@_;
    return 'same' unless $e->{kind} eq 'geo';
    return 'stale' unless GP_Fresh($cfg,$e,$now) && GP_AfterStart($s,$cfg,$e)
        && $e->{time}>=($s->{position_time}//0);
    my $old=GP_Geometry($c,$r,$e->{zone},$debug);
    my $g=$e->{geometry};
    return 'stale' unless GP_HasGeometry($g);
    my $different=!GP_HasGeometry($old) || grep {$g->{$_}!=$old->{$_}} qw(lat lon radius);
    return 'stale' if defined($old->{time}) && $e->{time}<$old->{time};
    my $conflict=$different && defined($old->{time}) && $e->{time}==$old->{time};
    return 'stale' if $old->{blocked} && $e->{time}<=($old->{time}//0) && !$conflict;
    my $changed=$different || $old->{blocked};
    my $next=$conflict ? {%$old,blocked=>1} : {%$g,time=>$e->{time},
        changed=>$changed ? $e->{time}:$old->{changed},blocked=>0,
        id=>lc GP_Attr($e->{zone},'zoneId',''),device=>lc GP_Attr($r,'deviceId','')};
    if ($GP_JSON->encode($next) ne $GP_JSON->encode($old)) {
        $c->{helper}{gp}{geometry}{$debug?'debug':'prod'}{$r}{$e->{zone}}=$next;
        $c->{helper}{gp}{geometry_dirty}{$r}{$e->{zone}}=1 unless $debug;
    }
    if ($changed) {
        GP_InvalidateConfig($c,$r,$debug);
        # Geometry is evaluated before GP_Process. Attribute its reset to this
        # webhook, not to the last phone poll or an earlier location event.
        local $s->{trace_context}={source=>'geo',zone=>$e->{zone},entry=>$e->{entry},
            observed=>$e->{time},received=>$e->{received},event_key=>$e->{key},
            geometry_changes=>join('; ',map {$_ . ': ' . (defined($old->{$_})?$old->{$_}:'unknown') . ' -> ' . $g->{$_}}
                grep {!defined($old->{$_}) || $old->{$_}!=$g->{$_}} qw(lat lon radius))};
        GP_RevokeGeometry($s,$e->{time},$now);
    }
    return $conflict ? 'conflict' : $changed ? 'changed':'same';
}

# GP_GeometrySync: Synchronize position after geometry changes without planning actions.
sub GP_GeometrySync {
    my ($s,$cfg,$e,$now,$mono)=@_;
    return unless $e->{kind} eq 'geo';
    my $zone=$cfg->{zones}{$e->{zone}} or return;
    local $s->{trace_context}={source=>'geo',zone=>$e->{zone},entry=>$e->{entry},
        observed=>$e->{time},received=>$e->{received},event_key=>$e->{key}};
    return if $e->{time}<($s->{position_time}//0);
    $s->{position_time}=$e->{time} if $e->{time}>=($s->{position_time}//0);
    if ($zone->{role} eq 'home' && $e->{entry}) {
        delete $s->{trip};
        $s->{phase}='home'; $s->{location}=$zone->{label}; $s->{desired_status}='home';
        GP_ResetNegative($s,$e->{time});
    } elsif (defined($mono) && $cfg->{geometry_ready} && !$s->{conflict}
        && $zone->{role} eq 'home' && !$e->{entry} && GP_Fresh($cfg,$e,$now)
        && GP_AfterStart($s,$cfg,$e) && $e->{time}>$s->{boundary}
        && $e->{key} && !$s->{seen}{$e->{key}}) {
        GP_RememberEvent($s,$e);
        return GP_Trace($s,$now,'Home departure after geometry update contradicted by newer phone presence')
            if GP_UsesSource($cfg->{sourceMode},'phone') && $s->{phone}{state} eq 'present'
                && ($s->{phone}{latest}//0)>=$e->{time};
        # All old permissions and phone qualifications have been revoked. This
        # same fresh exit can start a NEW suspicion, never confirm departure.
        # Only the changed-geometry batch supplies mono; incomplete geometry
        # and ordinary status-only synchronization cannot create a trip here.
        GP_LeaveHome($s,$cfg,$e,$mono);
        $s->{zones}{$e->{zone}}={entry=>0,time=>$e->{time},role=>'home'};
        $s->{location}='underway';
        $s->{last_observed}=$e->{time}; $s->{last_received}=$e->{received}; $s->{last_key}=$e->{key};
        return GP_Trace($s,$now,'Home departure pending after geometry update; new departure confirmation required',
            {home_exit=>$e->{time},departure_armed=>0});
    }
    GP_Trace($s,$now,'geometry synchronization; no actions');
}

# GP_PublishGeometry: Persist changed productive geometry as ordinary, event-free Readings.
sub GP_PublishGeometry {
    my ($c,$r,$s)=@_;
    my $rt=$c->{helper}{gp};
    for my $zone (sort keys %{$rt->{geometry_dirty}{$r}//{}}) {
        # Reading callbacks can change modes or reload the controller.
        last unless $c->{helper}{gp}==$rt && $rt->{ready}
            && GP_EffectiveMode($c,$r,0) eq 'active' && ($rt->{prod}{$r}//0)==$s;
        my $g=$rt->{geometry}{prod}{$r}{$zone};
        next unless $g && $defs{$zone};
        delete $rt->{geometry_dirty}{$r}{$zone};
        readingsBeginUpdate($defs{$zone});
        readingsBulkUpdate($defs{$zone},'gp_geometry',$GP_JSON->encode($g));
        GP_Profile($c,'geometry_reading_callbacks',$zone,sub {readingsEndUpdate($defs{$zone},1)});
    }
}

# GP_ApplyGeometry: Explicitly copy reviewed debug geometry into saved production metadata.
sub GP_ApplyGeometry {
    my ($c,$r)=@_;
    my $learned=GP_Learned($c,$r);
    return 'applyGeometry requires debug mode or a disabled resident with confirmed learning data'
        unless GP_EffectiveMode($c,$r,0) eq 'debug' || (GP_Mode($r) eq 'disabled' && $learned && $learned->{confirmed});
    return 'applyGeometry requires a Geofency resident'
        unless GP_UsesSource(GP_Attr($r,'sourceMode','geofency_phone'),'geo');
    my $rt=$c->{helper}{gp};
    return 'Confirm learning with set '.$r.' learnConfirm before applyGeometry'
        if GP_Mode($r) eq 'learning' || $c->{helper}{gp}{learning}{$r} || ($learned && !$learned->{confirmed});
    return 'applyGeometry requires real-time observations; use debugReset and fresh app tests after debugAdvance'
        if (($rt->{debug}{$r}//{})->{debug_offset}//0)!=0;
    my $cfg=GP_Config($c,$r,1);
    my @errors=GP_Validate($c,$r,0,$cfg);
    push @errors,@{$cfg->{geometry_errors}};
    my $now=GP_Now();my %updates;
    for my $zone (sort keys %{$cfg->{zones}}) {
        my $g=GP_Geometry($c,$r,$zone,1);
        unless (GP_ValidGeometryRecord($g,$r,$zone) && !$g->{blocked}
            && $g->{time}<=$now+$cfg->{future_tolerance}) {
            push @errors,"$zone: missing, conflicting or invalid debug geometry; send a fresh Geofency test";
            next;
        }
        my $old=GP_Geometry($c,$r,$zone,0);
        my $different=!GP_HasGeometry($old) || grep {$g->{$_}!=$old->{$_}} qw(lat lon radius);
        next if !$different && !$old->{blocked};
        if (defined($old->{time}) && $g->{time}<=$old->{time}) {
            push @errors,"$zone: production geometry is newer or conflicting at the same time; send a newer Geofency test";
            next;
        }
        # Copy geometry only, never visits, movement, trips or permissions. The
        # original timestamps remain intact; confirmation is not an observation.
        $updates{$zone}=$GP_JSON->encode({map {$_=>$g->{$_}} qw(lat lon radius time changed device id blocked)});
    }
    if (@errors) {
        my %seen;return "Geometry not applied; no readings changed:\n".join("\n",grep {!$seen{$_}++} @errors);
    }
    # Fully validate before changing anything. Revoke this resident's journeys
    # first. FHEM's low-level reading setter updates ordinary statefile data
    # without events, userReadings, stateFormat or output-adapter callbacks.
    GP_ResetResident($c,$r);
    my $stamp=POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime($now));
    setReadingsVal($defs{$_},'gp_geometry',$updates{$_},$stamp) for sort keys %updates;
    GP_Log($c,3,'geometry_applied',{resident=>$r,mode=>'debug',changed=>scalar(keys %updates),
        reason=>'Location geometry explicitly confirmed; trips reset; no actions'});
    return 'Geometry applied for '.scalar(keys %updates).' location(s); trips reset; no actions. '
        .'Geometry is stored in normal readings; use FHEM state saving for persistence.';
}

# GP_Config: Build or reuse a resident view with geometry from the selected runtime pool.
sub GP_Config {
    my ($c, $r, $debug) = @_;
    my $catalog=GP_Catalog($c);
    my $pool=$debug ? 'debug':'prod';
    return $catalog->{views}{$pool}{$r} if $catalog->{views}{$pool}{$r};
    $c->{helper}{gp_work}{config_builds}++ if $c->{helper}{gp_work};
    my $base=GP_BaseConfig($c,$r);
    my $cfg={%$base,zones=>{}};
    for my $n (keys %{$base->{zones}}) {
        my $g=GP_Geometry($c,$r,$n,$debug);
        $cfg->{zones}{$n}={%{$base->{zones}{$n}},(map {$_=>$g->{$_}} qw(lat lon radius)),blocked=>$g->{blocked}//0};
    }
    $cfg->{geometry_errors}=[GP_GeometryErrors($cfg)];
    $cfg->{geometry_ready}=!@{$cfg->{geometry_errors}} ? 1:0;
    return $catalog->{views}{$pool}{$r}=$cfg;
}

# GP_BaseConfig: Build or reuse a resident's static configuration and rule index.
sub GP_BaseConfig {
    my ($c,$r)=@_;
    my $catalog=GP_Catalog($c);
    return $catalog->{config}{$r} if $catalog->{config}{$r};
    my $source_mode=GP_Attr($r,'sourceMode','geofency_phone');
    my $phone=GP_UsesSource($source_mode,'phone');
    my $cfg = { resident => $r, roommate => $defs{$r}{ROOMMATE}, zones => {}, roles => {}, groups => {},
        zone_ids=>{},rules=>$catalog->{rules}{$r}//[],rule_index=>{},
        allowDoor => GP_Attr($r,'allowDoor',0), allowGarage => GP_Attr($r,'allowGarage',0),
        sourceMode => $source_mode,
        phoneSignalMode => $phone ? GP_Attr($r,'phoneSignalMode','state') : 'disabled',
        proxies => $phone ? [GP_List(GP_Attr($r,'phoneProxies',''))] : [],
        label => GP_Attr($defs{$r}{ROOMMATE},'alias',$defs{$r}{ROOMMATE}) };
    $cfg->{$_} = 0+GP_Attr($c->{NAME},$_,$GP_DEFAULT{$_}) for keys %GP_DEFAULT;
    for my $n (@{$catalog->{locations}{$r}//[]}) {
        my $d=$defs{$n};
        my $z = { name=>$n, role=>$d->{ROLE}, id=>lc GP_Attr($n,'zoneId',''),
            label=>GP_Attr($n,'label',$d->{ROLE} eq 'place' ? $n:$d->{ROLE}), groups=>[GP_List(GP_Attr($n,'groups',''))] };
        $cfg->{zones}{$n} = $z;
        push @{$cfg->{zone_ids}{$z->{id}}},$n;
        push @{$cfg->{roles}{$z->{role}}}, $n;
        push @{$cfg->{groups}{$_}},$n for @{$z->{groups}};
    }
    for my $rule (@{$cfg->{rules}}) {
        my @selectors=$rule->{trigger} eq 'arrival' ? ('arrival') : length($rule->{group})
            ? ('group:'.$rule->{group}) : map {'location:'.$_} @{$rule->{locations}};
        push @{$cfg->{rule_index}{$rule->{trigger}}{$_}},$rule for @selectors;
        $cfg->{notify_required}=1 if $rule->{type} eq 'notify';
    }
    return $catalog->{config}{$r}=$cfg;
}

# GP_ConfigRevision: Fingerprint configuration fields that determine observation and action semantics.
sub GP_ConfigRevision {
    my ($cfg)=@_;
    # Keep lookup indexes and memoized values out of the semantic fingerprint.
    # Adapter params contain only their allowed fields, shared by every rule.
    # Version 1 included a null revision through //= autovivification. Preserve
    # that encoding so ordinary existing checkpoints keep the same binding.
    $cfg->{revision}//=sha256_hex($GP_JSON->encode({revision=>undef,map {$_=>$cfg->{$_}}
        (qw(resident roommate zones roles groups rules allowDoor allowGarage sourceMode phoneSignalMode proxies label
            geometry_errors geometry_ready),keys %GP_DEFAULT)}));
    return $cfg->{revision};
}

# GP_Validate: Collect configuration errors for selected residents and activation requirements.
sub GP_Validate {
    my ($c, $only, $activation, $prepared_cfg) = @_;
    return ('Controller missing') unless $c;
    my $catalog=GP_Catalog($c);
    my @errors=@{$catalog->{common_errors}};
    my @res = defined($only) ? ($only) : GP_Residents($c);
    @res = grep { GP_Mode($_) eq 'active' } @res if $activation && !defined($only);
    push @errors,$c->{helper}{gp_http_error} if $c->{helper}{gp_http_error};
    for my $r (@res) {
        unless (GP_Field($r,'TYPE','') eq 'GeoPresence' && GP_Field($r,'SUBTYPE','') eq 'resident' && GP_Field($r,'CONTROLLER','') eq $c->{NAME}) {
            push @errors, "Unknown resident $r"; next;
        }
        my $cfg = $prepared_cfg && $prepared_cfg->{resident} eq $r ? $prepared_cfg : GP_BaseConfig($c,$r);
        $catalog->{errors}{$r}//=[GP_ValidateResident($c,$r,$cfg,$catalog)];
        push @errors,@{$catalog->{errors}{$r}};
        # Function availability and listener errors can change without a
        # configuration event. Sensor health is checked by the source adapters.
        push @errors,'pushMsg is not loaded' if $cfg->{notify_required} && !defined &pushMsg;
        push @errors,@{$catalog->{activation_errors}{$r}} if $activation && GP_Mode($c->{NAME}) eq 'active';
    }
    if (!defined($only) && !$activation) {
        push @errors,@{$catalog->{rule_errors}{$_}} for sort keys %{$catalog->{rule_errors}};
        push @errors,$catalog->{target_errors}{$_} for sort keys %{$catalog->{target_errors}};
    }
    my %seen;
    return grep {!$seen{$_}++} @errors;
}

# GP_ValidateResident: Check source, identity, location, and rule requirements for a resident.
sub GP_ValidateResident {
    my ($c,$r,$cfg,$catalog)=@_;
    my @errors;
    push @errors,"$r: remove obsolete attribute $_; use set mode" for grep {exists $attr{$r}{$_}} qw(mode operatingMode);
    push @errors,"$r: missing or invalid ROOMMATE $cfg->{roommate}" unless GP_Field($cfg->{roommate},'TYPE','') eq 'ROOMMATE';
    push @errors, "$r: invalid sourceMode" unless grep {$_ eq $cfg->{sourceMode}} @{$GP_ENUMS{sourceMode}};
    if (GP_UsesSource($cfg->{sourceMode},'phone')) {
        push @errors, "$r: phoneSignalMode must be state or measurement"
            unless $cfg->{phoneSignalMode} =~ /\A(?:state|measurement)\z/;
        my %proxy = map {$_=>1} @{$cfg->{proxies}};
        push @errors, "$r: phoneProxies must list the house sensors without duplicates"
            unless @{$cfg->{proxies}} && keys(%proxy)==@{$cfg->{proxies}};
        for my $p (@{$cfg->{proxies}}) {
            push @errors, "$r: invalid PRESENCE proxy $p" unless GP_Field($p,'TYPE','') eq 'PRESENCE';
        }
    }
    if (GP_UsesSource($cfg->{sourceMode},'geo')) {
        push @errors, "$r: deviceId and webhookUser required" unless GP_Id(GP_Attr($r,'deviceId','')) && GP_Id(GP_Attr($r,'webhookUser',''));
        my ($err, $secret) = GP_Auth($r);
        push @errors, "$r: set webhookPassword first" unless !$err && defined($secret) && $secret =~ /\A[0-9a-f]{32}:[0-9a-f]{64}\z/;
        for my $role (qw(home outer)) {
            my @locations=@{$cfg->{roles}{$role}//[]};
            if (@locations!=1) {
                my $detail=@locations ? 'found '.scalar(@locations).': '.join(', ',@locations)
                    : 'found 0; execute the define/attr commands returned by locationCommands';
                push @errors, "$r: exactly one $role location required ($detail)";
            }
        }
        push @errors, "$r: at most one approach location allowed" if @{$cfg->{roles}{approach}//[]}>1;
    }
    my %ids;
    for my $n (sort keys %{$cfg->{zones}}) {
        next unless GP_UsesSource($cfg->{sourceMode},'geo');
        my $z = $cfg->{zones}{$n};
        push @errors, "$n: invalid location function; use home, outer, approach or place" unless $z->{role} =~ /\A(?:home|outer|approach|place)\z/;
        my %tags;
        push @errors, "$n: invalid or duplicate groups" if @{$z->{groups}}>16 || grep {!GP_Group($_) || $tags{$_}++} @{$z->{groups}};
        push @errors, "$n: valid unique zoneId required" if !GP_Id($z->{id}) || $ids{$z->{id}}++;
    }
    my (%actions,%targets);
    for my $rule (@{$cfg->{rules}}) {
        push @errors,@{$catalog->{rule_errors}{$rule->{name}}//[]};
        push @errors, GP_ValidateRule($c,$rule,$r,$cfg);
        $actions{$rule->{action}}=1;
        $targets{$rule->{params}{target}}=1 if length($rule->{params}{target}//'');
    }
    push @errors,@{$catalog->{actions}{$_}{errors}//[]} for sort keys %actions;
    push @errors,$catalog->{target_errors}{$_} for grep {$catalog->{target_errors}{$_}} sort keys %targets;
    my $rr=$cfg->{roommate}; my @activation;
    push @activation,"$rr: remove rr_geofenceUUIDs before activation" if length GP_Attr($rr,'rr_geofenceUUIDs','');
    push @activation,"$rr: rr_locationUnderway must be underway" unless GP_Attr($rr,'rr_locationUnderway','') eq 'underway';
    (my $suffix=$rr)=~s/^rr_//;
    for my $old ("People.Loc.$suffix","People.handler.$suffix.enter") {
        push @activation,"$old: disable legacy action before activation" if exists($defs{$old}) && !GP_Attr($old,'disable',0);
    }
    $catalog->{activation_errors}{$r}=\@activation;
    return @errors;
}

# GP_ValidateRule: Check a rule's action, selectors, and arrival restrictions.
sub GP_ValidateRule {
    my ($c,$rule,$resident,$cfg) = @_;
    my @err; my $name=$rule->{name};
    my $a = $defs{$rule->{action}};
    return ("$name: action missing or in another controller") unless $a && ($a->{TYPE}//'') eq 'GeoPresence'
        && ($a->{SUBTYPE}//'') eq 'action' && ($a->{CONTROLLER}//'') eq $c->{NAME};
    push @err, "$name: invalid trigger; choose arrival, enter or exit" unless $rule->{trigger} =~ /\A(?:arrival|enter|exit)\z/;
    push @err, "$name: invalid arrivalFilter" unless ($rule->{arrivalFilter}//'any') =~ /\A(?:any|vehicle)\z/;
    for my $key (keys %{$attr{$name}//{}}) {
        push @err,"$name: $key is not applicable; remove it explicitly"
            if $key =~ /\A(?:locations|locationGroup|arrivalFilter)\z/ && !GP_RuleAttrEnabled($name,$key);
        push @err,"$name: unsupported rule attribute $key; remove it explicitly" if $key eq 'role' || $key eq 'condition';
    }
    if ($rule->{trigger} =~ /\A(?:enter|exit)\z/) {
        push @err,"$name: choose either locations or locationGroup"
            unless (@{$rule->{locations}} ? 1:0) + (length($rule->{group}) ? 1:0)==1;
        if (@{$rule->{locations}}) {
            my %seen;
            for my $z (@{$rule->{locations}}) {
                push @err, "$name: invalid or duplicate location $z" unless GP_Field($z,'TYPE','') eq 'GeoPresence' && GP_Field($z,'SUBTYPE','') eq 'location'
                    && GP_Field($z,'CONTROLLER','') eq $c->{NAME} && !$seen{$z}++;
                push @err,"$name: location $z belongs to a resident outside this rule"
                    unless grep {$_ eq GP_Field($z,'PARENT','')} GP_List(GP_Attr($name,'residents',''));
            }
            push @err,"$name: no selected location belongs to $resident" unless grep {$cfg->{zones}{$_}} @{$rule->{locations}};
        }
        push @err,"$name: group $rule->{group} has no locations for $resident"
            if length($rule->{group}) && (!GP_Group($rule->{group}) || !@{$cfg->{groups}{$rule->{group}}//[]});
    }
    if (length($rule->{afterExit})) {
        my ($kind,$ref)=split /:/,$rule->{afterExit},2;
        push @err,"$name: invalid afterExit for $resident; choose location:DEVICE or group:GROUP belonging to this resident"
            unless defined($ref) && (($kind eq 'location' && exists($cfg->{zones}{$ref}))
                || ($kind eq 'group' && GP_Group($ref) && @{$cfg->{groups}{$ref}//[]}));
    }
    if (GP_IsOpening($rule->{type})) {
        push @err, "$name: opening actions require confirmed arrival" unless $rule->{trigger} eq 'arrival';
        push @err, "$name: garage action requires arrivalFilter vehicle" if $rule->{type} eq 'garage_open' && $rule->{arrivalFilter} ne 'vehicle';
    }
    return @err;
}

# GP_ValidateAction: Check an adapter's required devices, fixed command, and permitted parameters.
sub GP_ValidateAction {
    my ($a)=@_;
    my ($name,$type,$p)=@{$a}{qw(name type params)};
    my @err;
    if ($type eq 'notify') {
        push @err,"$name: safe message required" unless GP_SafeText($p->{message}//'');
    } elsif ($type eq 'switch_on') {
        push @err,"$name: missing target device" unless GP_Name($p->{target}) && exists($defs{$p->{target}});
        push @err,"$name: command must be on" unless ($p->{command}//'') eq 'on';
    } elsif (GP_IsOpening($type)) {
        push @err,"$name: positionSignalMode must be state or measurement"
            unless ($p->{positionSignalMode}//'state') =~ /\A(?:state|measurement)\z/;
        my @refs=$type eq 'door_open' ? qw(target contact feedbackDevice) : qw(target stateDevice upperContact lowerContact);
        push @err,"$name: missing $_ device" for grep {!GP_Name($p->{$_}) || !exists($defs{$p->{$_}})} @refs;
        my $command=$type eq 'door_open' ? 'lock unlocked':'on';
        push @err,"$name: command must be $command" unless ($p->{command}//'') eq $command;
    } else { push @err,"$name: invalid action type"; }
    return @err;
}

# GP_SafeText: Check notification text against length and character restrictions.
sub GP_SafeText {
    my ($s) = @_;
    return defined($s) && length($s) && length($s)<=500 && $s !~ /[\x00-\x1f\x7f;{}\\]/;
}

# GP_ParseTime: Parse a strict ISO 8601 timestamp into epoch seconds and canonical time text.
sub GP_ParseTime {
    my ($s) = @_;
    return unless defined($s) && $s =~ /\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d{1,9})?(Z|[+-]\d\d:\d\d)\z/;
    my ($y,$m,$d,$h,$min,$sec,$frac,$off)=($1,$2,$3,$4,$5,$6,$7//0,$8);
    return if $y<2000 || $y>2100 || $h>23 || $min>59 || $sec>59 || $m<1 || $m>12 || $d<1 || $d>31;
    my $t=eval {timegm($sec,$min,$h,$d,$m-1,$y)};
    return if $@;
    my @check=gmtime($t);
    return unless $check[3]==$d && $check[4]+1==$m && $check[5]+1900==$y;
    if ($off ne 'Z') {
        $off =~ /([+-])(\d\d):(\d\d)/;
        return if $2>23 || $3>59;
        $t -= ($1 eq '+' ? 1 : -1) * ($2*3600+$3*60);
    }
    my $fraction=$frac eq '0' ? '' : ($frac =~ s/0+$//r);
    $fraction='' if $fraction eq '.';
    return ($t+0+$frac, sprintf('%d',$t).$fraction);
}

# GP_ReadingTime: Convert a FHEM Reading's local timestamp into epoch seconds.
sub GP_ReadingTime {
    my ($device,$reading)=@_;
    my $s=GP_Reading($device,$reading)->{TIME}//'';
    return unless $s =~ /\A(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\z/;
    my $t=eval {timelocal($6,$5,$4,$3,$2-1,$1)};
    return $@ ? undef : $t;
}

# GP_FormFieldLabel: Describe a form field for diagnostics without including its value.
sub GP_FormFieldLabel {
    my ($key,$number)=@_;
    return $key if $key =~ /\A(?:device|id|date|entry|isTest|name|latitude|longitude|radius|motion|currentLatitude|currentLongitude|address|wifiSSID|wifiBSSID|beaconUUID|major|minor|notes)\z/;
    return "extra field $number";
}

# GP_DecodeForm: Decode a bounded UTF-8 form into fields, an error, and diagnostic metadata.
sub GP_DecodeForm {
    my ($body)=@_;
    return (undef,'Request too large') if length($body)>16384;
    my %p;my @multiline;
    my %used=map {$_=>1} qw(device id date entry isTest name latitude longitude radius motion currentLatitude currentLongitude);
    for my $pair (split /&/, $body) {
        next unless length $pair;
        my ($k,$v)=split /=/,$pair,2;
        return (undef,'Malformed form data') unless defined $v;
        my $part=0;
        for ($k,$v) {
            return (undef,'Invalid percent encoding') if /%(?![0-9a-fA-F]{2})/;
            tr/+/ /;
            s/%([0-9a-fA-F]{2})/chr(hex($1))/eg;
            $_=eval {decode('UTF-8',$_,FB_CROAK)};
            return (undef,'Invalid UTF-8') if $@;
            my $field=$part ? GP_FormFieldLabel($k,1+keys(%p)) : 'field name';
            # Addresses and other unused metadata may legitimately be multiline.
            # Decision fields and field names remain strict; nothing is trimmed
            # into a valid device ID, timestamp, entry, coordinate or motion.
            my $control=($part && !$used{$k}) ? qr/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/ : qr/[\x00-\x1f\x7f]/;
            return (undef,sprintf('Control character U+%04X in %s',ord($1),$field)) if /($control)/;
            $part++;
        }
        return (undef,'Invalid form field name') unless $k =~ /\A[A-Za-z][A-Za-z0-9_.-]{0,63}\z/;
        return (undef,'Duplicate form field') if exists $p{$k};
        push @multiline,GP_FormFieldLabel($k,1+keys(%p)) if $v =~ /[\t\r\n]/;
        $p{$k}=$v;
        return (undef,'Too many fields') if keys(%p)>50;
    }
    return (\%p,undef,{ignored_multiline=>join(',',@multiline)});
}

# GP_NewPhone: Create an enabled or disabled phone-continuity state.
sub GP_NewPhone {
    return {state=>'disabled',health=>'disabled',samples=>{},ever_present=>0} if defined($_[0]) && !$_[0];
    return {state=>'unknown',health=>'unknown',samples=>{},ever_present=>0};
}

# GP_ResetNegative: Clear absence qualification and optionally advance its observation boundary.
sub GP_ResetNegative {
    my ($s,$after)=@_;
    my $p=$s->{phone};
    delete @{$p}{qw(negative_since negative_wall negative_first negative_renewed_at negative_renewed_mono qualified)};
    $p->{negative_generation}=($p->{negative_generation}//0)+1 if defined $after;
    $p->{negative_after}=$after if defined($after) && $after>($p->{negative_after}//0);
}

# GP_NewState: Create a resident context with independent trip and output namespaces.
sub GP_NewState {
    my ($now,$mono,$generation,$source_mode)=@_;
    # A fresh namespace keeps local trip counters distinct across process starts
    # and context resets, even when their clocks and startup counters repeat.
    $generation=sha256_hex(join(':',$generation,$now,$mono,$$,rand()));
    return {start=>$now, generation=>$generation, phase=>'unknown', zones=>{}, seen=>{}, seen_order=>[],
        boundary=>0, seq=>0, phone=>GP_NewPhone(GP_UsesSource($source_mode,'phone')),
        last_decision=>'initialized', last_reason=>'new session; no qualified trip restored',
        mono=>$mono, wall=>$now, output_revision=>0, action_visits=>{}, action_last=>{}, trace=>[], intents=>[]};
}

# GP_RevokeOutputs: Invalidate existing intent revisions and clear pending output plans.
sub GP_RevokeOutputs {
    my ($s)=@_;
    $s->{output_revision}++;
    $s->{intents}=[];
}

# GP_RevokeDependentOutputs: Revoke plans for residents that depend on changed device names.
sub GP_RevokeDependentOutputs {
    my ($c,@names)=@_;
    my $rt=$c->{helper}{gp} or return;
    my $dependencies=$c->{helper}{gp_output_dependencies}//{};
    my %affected;
    $affected{$_}=1 for map {keys %{$dependencies->{$_}//{}}} @names;
    for my $r (keys %affected) {
        GP_RevokeOutputs($rt->{$_}{$r}) for grep {$rt->{$_}{$r}} qw(prod debug);
    }
}

# GP_Trace: Append a bounded decision record with its observation and session context.
sub GP_Trace {
    my ($s,$now,$reason,$extra)=@_;
    unless (($extra//{})->{diagnostic_only}) {
        $s->{last_reason}=$reason;
        $s->{last_decision}=($extra // {})->{decision} // $reason;
    }
    push @{$s->{trace}}, {time=>$now,reason=>$reason,sequence=>++$s->{trace_sequence},generation=>$s->{generation},phase=>$s->{phase},
        trip=>$s->{trip} ? $s->{trip}{id} : '',observed=>$s->{last_observed},received=>$s->{last_received},
        event_key=>$s->{last_key},config_revision=>$s->{config_revision},phone_mode=>$s->{phone}{state} eq 'disabled' ? 'disabled':$s->{phone_mode}//'live',
        %{$s->{trace_context}//{}},%{$extra//{}}};
    shift @{$s->{trace}} while @{$s->{trace}}>1000;
}

# GP_StartTrip: Create an unarmed trip when no current trip exists.
sub GP_StartTrip {
    my ($s,$event,$scope)=@_;
    return $s->{trip} if $s->{trip};
    delete @{$s}{qw(approach automotive motion motion_time)};
    $s->{trip}={id=>$s->{generation}.':'.++$s->{seq}, start=>$event->{time}, scope=>$scope//'local',
        armed=>0, actions=>{}, home_exit=>undef};
    return $s->{trip};
}

# GP_LeaveHome: Record a Home exit and begin a new absence-qualification interval.
sub GP_LeaveHome {
    my ($s,$cfg,$e,$mono)=@_;
    my $trip=GP_StartTrip($s,$e,'local');
    $trip->{home_exit}=$e->{time}; $trip->{leave_mono}=$mono;
    GP_ResetNegative($s,$e->{time});
    # A new full interval may use held negatives observed in this session.
    # Measurement sources still need actual new observations after the exit.
    $s->{phone}{negative_after}=$s->{start} if ($cfg->{phoneSignalMode}//'state') eq 'state';
    $s->{phase}='leaving';
}

# GP_DepartureTime: Return the departure boundary relevant to later phone presence.
sub GP_DepartureTime {
    my ($trip)=@_;
    return unless $trip;
    my $time=$trip->{away_time}//$trip->{start};
    return $trip->{home_exit} if defined($trip->{home_exit})
        && (!defined($time) || $trip->{home_exit}>$time);
    return $time;
}

# GP_Fresh: Check observation and receipt ages against freshness and future limits.
sub GP_Fresh {
    my ($cfg,$e,$now)=@_;
    return $now-$e->{time}<=$cfg->{action_max_age} && $e->{time}<=$now+$cfg->{future_tolerance}
        && $now-$e->{received}<=$cfg->{action_max_age};
}

# GP_AfterStart: Apply the session-start boundary, including validated restart recovery.
sub GP_AfterStart {
    my ($s,$cfg,$e)=@_;
    # A validated saved departure already supplies the missing initial context.
    # Its NEW Geo return may arrive immediately after startup, but a pre-start
    # webhook still cannot execute. Other startup states retain their old guard.
    my $recovered=defined($s->{resume_event_floor}) && $s->{resume_event_floor}==$s->{start};
    my $margin=$e->{kind} eq 'geo' && !$recovered
        ? $cfg->{future_tolerance}:0;
    return $e->{time}>$s->{start}+$margin;
}

# GP_AwayLongEnough: Check that a return follows the full absolute and monotonic absence interval.
sub GP_AwayLongEnough {
    my ($cfg,$trip,$e,$mono)=@_;
    my $phone=($trip->{away_reason}//'') eq $GP_PHONE_DEPARTURE_REASON;
    my $proof=$trip->{phone_qualification};
    my $minimum=$cfg->{minimum_away};
    $minimum=$cfg->{phone_absence_window} if $phone && $cfg->{phone_absence_window}>$minimum;
    # A delayed or future-dated return cannot acquire an absence confirmation
    # which had not completed when it was observed and received.
    return $e->{time}-$trip->{away_time}>=$minimum
        && ($e->{received_mono}//$mono)-$trip->{away_mono}>=$minimum
        && (!$proof || ($e->{time}>=$proof->{qualified_at}
            && ($e->{received_mono}//$mono)>=$proof->{qualified_mono}));
}

# GP_RememberEvent: Retain bounded duplicate-detection metadata and the original receipt clocks.
sub GP_RememberEvent {
    my ($s,$e)=@_;
    return unless $e->{key};
    $s->{seen}{$e->{key}}={motion=>$e->{motion}//'unknown',received=>$e->{received},received_mono=>$e->{received_mono}};
    push @{$s->{seen_order}},$e->{key};
    delete $s->{seen}{shift @{$s->{seen_order}}} while @{$s->{seen_order}}>2000;
}

# GP_UsefulMotion: Recognize motion values that affect arrival timing or vehicle eligibility.
sub GP_UsefulMotion {
    return ($_[0]//'') =~ /\A(?:automotive|walking|running|cycling)\z/;
}

# GP_MotionOrigin: Find an accepted observation allowed to supply motion to this approach or arrival.
sub GP_MotionOrigin {
    my ($s,$cfg,$e)=@_;
    my $origin=$s->{arrival}//$s->{approach};
    my $seen=$s->{seen}{$e->{key}//''};
    my $zone=$cfg->{zones}{$e->{zone}//''}//{};
    my $previous=$s->{zones}{$e->{zone}//''}//{};
    # The current approach and accepted entries belong to the pending arrival
    # even after newer empty entries. Cancelled/completed arrivals donate no data.
    return unless $origin && $e->{time}>=$origin->{origin_time}
        && ref($seen) eq 'HASH' && !GP_UsefulMotion($seen->{motion}) && GP_UsefulMotion($e->{motion})
        && $e->{kind} eq 'geo' && $e->{entry} && ($zone->{role}//'') =~ /\A(?:home|approach)\z/
        && $cfg->{geometry_ready} && !$s->{conflict} && $s->{trip} && $s->{trip}{armed} && $s->{phase} eq 'returning'
        && $previous->{entry} && $e->{time}>$s->{boundary} && $e->{time}>=($s->{motion_time}//0)
        && !(($s->{motion_time}//0)==$e->{time} && GP_UsefulMotion($s->{motion}));
    my $p=$s->{arrival};
    return unless $p
        ? defined($seen->{arrival_key}) && $seen->{arrival_key} eq ($p->{event}{key}//'')
            && $p->{trip} eq $s->{trip}{id} && $p->{generation} eq $s->{generation}
        : $previous->{time}==$e->{time} && $e->{time}>=($s->{position_time}//0);
    return $seen;
}

# GP_EnrichDuplicate: Add missing motion without refreshing the original observation or receipt times.
sub GP_EnrichDuplicate {
    my ($s,$cfg,$e,$now,$mono)=@_;
    my $seen=GP_MotionOrigin($s,$cfg,$e) or return;
    $seen->{motion}=$e->{motion};
    $s->{motion}=$e->{motion}; $s->{motion_time}=$e->{time};
    $s->{automotive}=$e->{time} if $e->{motion} eq 'automotive';
    $s->{checkpoint_dirty}=1;
    if (my $p=$s->{arrival}) {
        # Keep the first receipt and original observation time. A retry cannot
        # refresh motion freshness or restart the Home wait.
        my $enriched={%$e,received=>$seen->{received},received_mono=>$seen->{received_mono},role=>$cfg->{zones}{$e->{zone}}{role}};
        $p->{event}{motion}=$e->{motion} if ($p->{event}{key}//'') eq $e->{key};
        GP_BeginArrival($s,$cfg,$enriched,$now,$mono);
    }
    GP_Trace($s,$now,'duplicate event enriched with motion',{motion=>$e->{motion},motion_time=>$e->{time}});
    return 1;
}

# GP_MergeBatchMotion: Enrich the first duplicate in a batch before arrival planning can consume it.
sub GP_MergeBatchMotion {
    my (@events)=@_;
    my %first;
    for my $e (@events) {
        next unless $e->{kind} eq 'geo' && $e->{key};
        my $prior=$first{$e->{key}};
        if (!$prior) { $first{$e->{key}}=$e; next; }
        # Make a richer duplicate available BEFORE any arrival in this batch
        # can consume the trip (including a simultaneous phone confirmation).
        $prior->{motion}=$e->{motion} if !GP_UsefulMotion($prior->{motion}) && GP_UsefulMotion($e->{motion});
    }
}

# GP_PhoneVeto: Check whether current phone presence contradicts a proposed Geo departure.
sub GP_PhoneVeto {
    my ($s,$cfg,$time)=@_;
    my $p=$s->{phone};
    return GP_UsesSource($cfg->{sourceMode},'phone') && $p->{state} eq 'present'
        && (($p->{latest}//0)>=$time || $p->{health} eq 'handover'
            || (($cfg->{phoneSignalMode}//'state') eq 'state' && $p->{health} eq 'held'));
}

# GP_Arm: Qualify a departure while respecting contradictory phone evidence.
sub GP_Arm {
    my ($s,$cfg,$e,$now,$mono,$scope,$previous_position)=@_;
    # Measurement timestamps order evidence. A latched positive state remains
    # current until a transition or fault; an old timestamp does not imply absence.
    # A short handover preserves this continuity in either source mode, including
    # its veto of contradictory Geo departures before another room sees the phone.
    if (GP_PhoneVeto($s,$cfg,$e->{time})) {
        # Held presence vetoes this outer observation, but does not disprove an
        # earlier Home exit observed AFTER the last actual positive phone sample.
        # Retain only that unarmed local suspicion, never remote/work permissions.
        my $home=$s->{trip};
        my $retain=$home && !$home->{armed} && ($home->{scope}//'') eq 'local'
            && defined($home->{home_exit}) && $home->{home_exit}>($s->{phone}{latest}//0);
        delete @{$s}{qw(trip arrival approach automotive motion motion_time)};
        my $detail={phone_state=>$s->{phone}{state},phone_health=>$s->{phone}{health},phone_latest=>$s->{phone}{latest}};
        if ($retain) {
            # Same trip keeps its consumption; rejected departure evidence does not.
            $s->{trip}={map({$_=>$home->{$_}} qw(id start home_exit leave_mono)),scope=>'local',armed=>0,actions=>$home->{actions}//{}};
            $s->{phase}='leaving'; $s->{location}='underway';
            # The rejected event must neither supersede earlier negative samples
            # nor restart their running qualification or demand a new transition.
            $s->{position_time}=$previous_position;
            GP_Trace($s,$now,'departure rejected; pending Home exit retained',{%$detail,home_exit=>$home->{home_exit}});
            return 0;
        }
        $s->{phase}='home'; $s->{location}='home'; $s->{desired_status}='home';
        $s->{position_time}=$s->{phone}{latest} if $s->{phone}{latest}>($s->{position_time}//0);
        GP_ResetNegative($s,$s->{position_time});
        GP_Trace($s,$now,'departure contradicted by current local presence',$detail);
        return 0;
    }
    # A renewed, accepted departure ends the previous arrival section even
    # when the physical trip remains open and no approach exit was delivered.
    delete @{$s}{qw(automotive motion motion_time)} if $s->{phase} eq 'returning';
    GP_CancelArrival($s,$now,'new departure observation');
    my $trip=GP_StartTrip($s,$e,$scope);
    $trip->{scope}='remote' if ($scope//'') eq 'remote';
    unless ($trip->{armed}) {
        $trip->{armed}=1; $trip->{away_time}=$e->{time}; $trip->{away_mono}=$mono;
        $trip->{away_reason}=$e->{zone}//$e->{kind};
    }
    $s->{phase}='away';
    return 1;
}

# GP_VehicleEligible: Evaluate recent movement and remote-trip evidence for garage eligibility.
sub GP_VehicleEligible {
    my ($s,$cfg,$now)=@_;
    return 1 if defined($s->{automotive}) && $now-$s->{automotive}<=$cfg->{motion_max_age};
    return 0 if ($s->{motion}//'') =~ /\A(?:walking|running|cycling)\z/ && $now-($s->{motion_time}//0)<=$cfg->{motion_max_age};
    return $s->{trip} && ($s->{trip}{scope}//'') eq 'remote';
}

# GP_LocationEvents: Update explicit memberships and derive location and group transitions.
# Explicit membership is separate from the display's geometric/age inference.
# Missing exits and expired readings never manufacture a group exit.
sub GP_LocationEvents {
    my ($s,$cfg,$e)=@_;
    my $zone=$e->{zone}; my $members=$s->{members}//={};
    my $previous=$members->{$zone};
    my %before=map {my $g=$_; $g=>scalar(grep {$members->{$_} && $members->{$_}{entry}} @{$cfg->{groups}{$g}})}
        @{$cfg->{zones}{$zone}{groups}};
    $s->{zone_visits}{$zone}++ if $e->{entry} && (!$previous || !$previous->{entry});
    $s->{zone_visits}{$zone}//=1;
    $members->{$zone}={entry=>$e->{entry},time=>$e->{time}};
    my @events=({%$e,selector=>'location:'.$zone});
    my $exits=$s->{trip} ? ($s->{trip}{exits}//={}):undef;
    # A confirmed return can leave intents awaiting dispatch in this same batch.
    # Reentry must also revoke their evidence in the just-completed trip.
    my $completed=($s->{last_trip}//{})->{exits};
    delete $completed->{'location:'.$zone} if $completed && $e->{entry};
    if ($exits) {
        if ($e->{entry}) { delete $exits->{'location:'.$zone}; }
        elsif (!$previous || $previous->{entry}) { $exits->{'location:'.$zone}=$e->{time}; }
    }
    for my $group (@{$cfg->{zones}{$zone}{groups}}) {
        my $inside=grep {$members->{$_} && $members->{$_}{entry}} @{$cfg->{groups}{$group}};
        delete $exits->{'group:'.$group} if $exits && $e->{entry};
        delete $completed->{'group:'.$group} if $completed && $e->{entry};
        my $transition=$e->{entry} ? !$before{$group} : !$inside && ($before{$group} || !$previous);
        next unless $transition;
        $s->{group_visits}{$group}++ if $e->{entry};
        $s->{group_visits}{$group}//=1;
        $exits->{'group:'.$group}=$e->{time} if $exits && !$e->{entry};
        push @events,{%$e,group=>$group,selector=>'group:'.$group};
    }
    return @events;
}

# GP_ExitEvidence: Find an explicit prior exit within the current trip and before the trigger.
sub GP_ExitEvidence {
    my ($s,$reference,$time)=@_;
    my $trip=$s->{trip} or return;
    my $exit=($trip->{exits}//{})->{$reference};
    return defined($exit) && $exit>=$trip->{start} && $exit<$time ? $exit:undef;
}

# GP_ConsumptionSlot: Derive an action's consumption key and whether it belongs to the trip.
sub GP_ConsumptionSlot {
    my ($rule,$selector)=@_;
    return (join('|',$rule->{type},$rule->{params}{target}//''),1) if GP_IsOpening($rule->{type});
    return (join('|',$rule->{action},$rule->{trigger},$selector),
        $rule->{trigger} eq 'arrival' || length($rule->{afterExit}//'') ? 1:0);
}

# GP_ConsumptionSlots: Cache the configured consumption and cooldown slots needed by recovery.
# Prepared once per configuration, only when recovery or migration needs it.
sub GP_ConsumptionSlots {
    my ($cfg)=@_;
    return $cfg->{consumption_slots} if $cfg->{consumption_slots};
    my $slots={trip=>{},visit=>{},last=>{}};
    for my $trigger (keys %{$cfg->{rule_index}}) {
        for my $selector (keys %{$cfg->{rule_index}{$trigger}}) {
            for my $rule (@{$cfg->{rule_index}{$trigger}{$selector}}) {
                my ($key,$trip)=GP_ConsumptionSlot($rule,$selector);
                if ($trip) { $slots->{trip}{$key}=$rule->{type}; }
                else {
                    my ($kind,$name)=split /:/,$selector,2;
                    $slots->{visit}{$key}=[$kind eq 'group' ? 'group_visits':'zone_visits',$name];
                }
                $slots->{last}{$rule->{action}}=1 unless GP_IsOpening($rule->{type});
            }
        }
    }
    return $cfg->{consumption_slots}=$slots;
}

# GP_CompactConsumption: Import current consumption from legacy history without retaining past visits.
# One-time import for version 1 checkpoints and live states from an older module.
# Read only the current visit/trip keys; never carry the old history forward.
sub GP_CompactConsumption {
    my ($cfg,$trip,$state)=@_;
    my $slots=GP_ConsumptionSlots($cfg);
    my $seen=delete($state->{notify_seen})//{};
    my $actions=$trip->{actions}//{};
    my $last=delete($state->{notify_last})//{};
    delete $state->{notify_order};
    $trip->{actions}={}; $state->{action_visits}={};
    $state->{action_last}={map {$_=>$last->{$_}} grep {exists $last->{$_}} keys %{$slots->{last}}};
    for my $key (keys %{$slots->{trip}}) {
        my $opening=GP_IsOpening($slots->{trip}{$key});
        my $old;
        if ($opening) { $old=$trip->{id}.'|'.$key; }
        else {
            my ($action,$trigger,$selector)=split /\|/,$key,3;
            $old=join('|',$action,$trigger,$trip->{id},$selector);
        }
        $trip->{actions}{$key}=1 if $opening ? $actions->{$old}:$seen->{$old};
    }
    for my $key (keys %{$slots->{visit}}) {
        my ($field,$name)=@{$slots->{visit}{$key}};
        my $visit=($state->{$field}//{})->{$name}//0;
        my ($action,$trigger,$selector)=split /\|/,$key,3;
        $state->{action_visits}{$key}=$visit if $seen->{join('|',$action,$trigger,$visit,$selector)};
    }
}

# GP_Rules: Plan matching actions after permission, consumption, and cooldown checks.
sub GP_Rules {
    my ($s,$cfg,$trigger,$e,$now,$mono)=@_;
    my $selector=$trigger eq 'arrival' ? 'arrival' : length($e->{group}//'')
        ? 'group:'.$e->{group} : 'location:'.($e->{zone}//'');
    for my $rule (@{($cfg->{rule_index}{$trigger}//{})->{$selector}//[]}) {
        my $skip=sub {GP_Trace($s,$now,$_[0],{rule=>$rule->{name},decision=>'suppressed'})};
        my $after=$rule->{afterExit}//'';
        my $exit=length($after) ? GP_ExitEvidence($s,$after,$e->{time}):undef;
        if (length($after) && !defined($exit)) { $skip->('required prior exit not observed in this trip'); next; }
        if (($rule->{arrivalFilter}//'any') eq 'vehicle' && !(exists($e->{arrival_vehicle_eligible})
            ? $e->{arrival_vehicle_eligible} : GP_VehicleEligible($s,$cfg,$now))) {
            $skip->('no qualifying car or remote evidence, or current walking/cycling'); next;
        }
        my $type=$rule->{type}; my $opening=GP_IsOpening($type);
        if ($trigger eq 'arrival' || $opening) {
            unless (GP_UsesSource($cfg->{sourceMode},'geo')) { $skip->('source profile does not authorize arrival actions'); next; }
            unless ($cfg->{geometry_ready}) { $skip->('geometry not ready'); next; }
            unless ($s->{trip} && $s->{trip}{armed} && !$s->{conflict}) { $skip->('departure not confirmed'); next; }
            unless (GP_AwayLongEnough($cfg,$s->{trip},$e,$mono)) { $skip->('return before minimum away time'); next; }
        }
        if ($opening) {
            unless ($trigger eq 'arrival') { $skip->('opening requires confirmed arrival'); next; }
            if (($type eq 'door_open' && !$cfg->{allowDoor}) || ($type eq 'garage_open' && !$cfg->{allowGarage})) {
                $skip->('resident has no permission for this actor'); next;
            }
        }
        my ($key,$trip_bound)=GP_ConsumptionSlot($rule,$selector);
        my $consumed=$trip_bound ? ($s->{trip}{actions}//={}) : ($s->{action_visits}//={});
        my $visit=$trip_bound ? 1
            : length($e->{group}//'') ? ($s->{group_visits}{$e->{group}}//0) : ($s->{zone_visits}{$e->{zone}}//0);
        my $label=$type eq 'switch_on' ? 'switch' : 'notification';
        if (defined($consumed->{$key}) && $consumed->{$key}==$visit) {
            $skip->($opening ? 'action already consumed in this trip':"$label already consumed"); next;
        }
        if (!$opening && defined($s->{action_last}{$rule->{action}})
            && $now-$s->{action_last}{$rule->{action}}<$rule->{cooldown}) { $skip->("$label cooldown"); next; }
        $consumed->{$key}=$visit;
        $s->{action_last}{$rule->{action}}=$now unless $opening;
        $s->{checkpoint_dirty}=1;
        my %history=length($after) ? (after_exit=>$after,exit_time=>$exit):();
        $history{trip}=$s->{trip}{id} if $trip_bound;
        push @{$s->{intents}}, {kind=>$type,key=>$key,rule=>$rule->{name},trigger=>$trigger,%history,
            params=>$rule->{params},e=>{%$e},generation=>$s->{generation},output_revision=>$s->{output_revision},
            expires_mono=>GP_ActionMonoExpiry($cfg,$e,$now,$mono)};
    }
}

# GP_CancelArrival: Discard the approach and cancel any pending Home arrival.
sub GP_CancelArrival {
    my ($s,$now,$reason)=@_;
    delete $s->{approach};
    return unless delete $s->{arrival};
    GP_Trace($s,$now,'arrival cancelled',{confirmation=>$reason});
}

# GP_InterruptsArrival: Check whether a technical-zone exit interrupts the current arrival origin.
sub GP_InterruptsArrival {
    my ($s,$cfg,$e)=@_;
    my $origin=$s->{arrival}//$s->{approach};
    return $origin && $e->{kind} eq 'geo' && !$e->{entry}
        && $e->{time}>=$origin->{origin_time}
        && (($cfg->{zones}{$e->{zone}}//{})->{role}//'') =~ /\A(?:home|approach|outer)\z/;
}

# GP_ArrivalMotion: Select movement evidence fresh enough to determine the arrival wait.
sub GP_ArrivalMotion {
    my ($s,$cfg,$now)=@_;
    my $motion=$s->{motion}//'unknown';
    my $age=$now-($s->{motion_time}//0);
    # A useful foot observation survives an empty Home payload. Faster waits
    # require newer evidence than the independent garage permission does.
    my $limit=$motion eq 'walking' ? $cfg->{motion_max_age} : $cfg->{arrival_motion_max_age};
    return 'unknown' unless $motion =~ /\A(?:walking|running|cycling|automotive)\z/
        && $age>=-$cfg->{future_tolerance} && $age<=$limit;
    return $motion;
}

# GP_UpdateArrivalMotion: Refresh a pending arrival's motion decision while retaining its time anchors.
sub GP_UpdateArrivalMotion {
    my ($s,$cfg,$p,$now,$evaluated_at)=@_;
    # Revoking older evidence must not age an unaffected, latched decision.
    # New motion uses now; a partial revocation keeps its original evaluation.
    $p->{vehicle_eligible}=GP_VehicleEligible($s,$cfg,$evaluated_at)?1:0;
    my $motion=GP_ArrivalMotion($s,$cfg,$evaluated_at);
    my $wait=$cfg->{'arrival_wait_'.$motion};
    my $changed=!defined($p->{wait}) || $p->{wait}!=$wait || $p->{motion} ne $motion;
    $p->{motion_evaluated_at}=$evaluated_at;
    $p->{motion}=$motion; $p->{motion_time}=$s->{motion_time}; $p->{wait}=$wait;
    $p->{due_mono}=$p->{start_mono}+$wait;
    $p->{deadline}=$p->{started}+$wait;
    GP_Trace($s,$now,'arrival pending',{motion=>$motion,motion_time=>$p->{motion_time},
        wait_seconds=>$wait,deadline=>$p->{deadline}}) if $changed;
}

# GP_BeginArrival: Create or update a qualified Home arrival and its motion-based wait.
sub GP_BeginArrival {
    my ($s,$cfg,$e,$now,$mono)=@_;
    my $p=$s->{arrival};
    my $home=$p ? $p->{event}:$e;
    # Status-only synchronization and premature returns cannot acquire a new
    # opening permission merely by waiting out minimum_away at Home. An older
    # approach supplement cannot replace the Home event that qualified the wait.
    unless ($s->{trip} && $s->{trip}{armed} && !$s->{conflict}
        && GP_AwayLongEnough($cfg,$s->{trip},$home,$mono)) {
        return GP_Arrive($s,$cfg,$e,$now,$mono);
    }
    if (!$p) {
        # Count from server receipt, never from a phone's possibly delayed date.
        # The reorder window is part of the wait, not an additional full wait.
        $p=$s->{arrival}={event=>{%$e},trip=>$s->{trip}{id},generation=>$s->{generation},
            origin_time=>($s->{approach}//{})->{origin_time}//$e->{time},
            start_mono=>$e->{received_mono},started=>$e->{received}};
    }
    # Transfer the still-current approach origin without scanning event history.
    for my $key ($e->{key},($s->{approach}//{})->{key}) {
        $s->{seen}{$key}{arrival_key}=$p->{event}{key}
            if $key && $s->{seen}{$key} && $p->{event}{key};
    }
    $p->{latest_home}={%$e} if ($e->{role}//'') eq 'home'
        && (!$p->{latest_home} || $e->{time}>=$p->{latest_home}{time});
    if (defined($p->{wait}) && !GP_UsefulMotion($e->{motion})) {
        # Repeated entry webhooks with no new evidence neither restart the wait
        # nor allow a walking veto to expire into a remote garage permission.
        return;
    }
    $s->{phase}='returning';
    delete $s->{approach};
    GP_UpdateArrivalMotion($s,$cfg,$p,$now,$now);
}

# GP_ActionFresh: Check an action's absolute expiry, including its allowed arrival wait.
sub GP_ActionFresh {
    my ($cfg,$e,$now)=@_;
    # Only the module's confirmation path supplies this allowance. Keep the
    # original event date/receipt; deliberate waiting does not turn a late retry
    # into a fresh observation or permit unbounded execution after a timer stall.
    return $e->{time}<=$now+$cfg->{future_tolerance} && $now<=GP_ActionExpiry($cfg,$e);
}

# GP_ActionExpiry: Derive absolute expiry from the oldest observation or receipt time.
sub GP_ActionExpiry {
    my ($cfg,$e)=@_;
    my $oldest=$e->{time}<$e->{received} ? $e->{time}:$e->{received};
    return $oldest+$cfg->{action_max_age}+($e->{arrival_wait_budget}//0);
}

# GP_ActionMonoExpiry: Anchor an action's remaining time budget to its monotonic receipt clock.
sub GP_ActionMonoExpiry {
    my ($cfg,$e,$now,$mono)=@_;
    # Convert the observation's age at receipt only once. Later wall-clock
    # corrections must not refund time spent queued or waiting for arrival.
    my $received=$e->{received_mono}//($mono-($now-$e->{received}));
    return $received+GP_ActionExpiry($cfg,$e)-$e->{received};
}

# GP_ConfirmArrival: Complete a due Home wait only while its evidence and time budgets remain valid.
sub GP_ConfirmArrival {
    my ($s,$cfg,$now,$mono)=@_;
    my $p=$s->{arrival} or return;
    return if $mono<$p->{due_mono};
    unless ($s->{trip} && $s->{trip}{armed} && $p->{trip} eq $s->{trip}{id}
        && $p->{generation} eq $s->{generation} && !$s->{conflict}
        && $cfg->{geometry_ready} && $s->{phase} eq 'returning'
        && ($s->{zones}{$p->{event}{zone}}//{})->{entry}) {
        return GP_CancelArrival($s,$now,'arrival evidence revoked');
    }
    my $e={%{$p->{event}},arrival_wait_budget=>$p->{wait},
        arrival_vehicle_eligible=>$p->{vehicle_eligible},confirmation=>'timer'};
    unless (GP_ActionFresh($cfg,$e,$now) && $mono<=GP_ActionMonoExpiry($cfg,$e,$now,$mono)) {
        GP_CancelArrival($s,$now,'arrival confirmation expired');
        $s->{phase}='away';
        return;
    }
    GP_Arrive($s,$cfg,$e,$now,$mono);
}

# GP_Arrive: Finalize an arrival, plan eligible rules, and close its current trip.
sub GP_Arrive {
    my ($s,$cfg,$e,$now,$mono)=@_;
    local $s->{trace_context}={source=>$e->{kind},zone=>$e->{zone}};
    my $pending=delete $s->{arrival};
    # A new local phone return may finish the same provisional Home arrival.
    # Preserve its motion-based garage decision across the confirmation wait.
    $e={%$e,arrival_vehicle_eligible=>$pending->{vehicle_eligible}} if $pending && $e->{kind} eq 'phone_present';
    GP_Trace($s,$now,'arrival confirmed', {source=>$e->{kind}, time_observed=>$e->{time},changed=>$s->{phase} ne 'home' ? 1:0,
        observed=>$e->{time},received=>$e->{received},event_key=>$e->{key},
        confirmation=>$e->{confirmation}//($e->{kind} eq 'phone_present' ? 'phone':'status only'),
        motion=>$pending ? $pending->{motion}:$s->{motion},wait_seconds=>$pending ? $mono-$pending->{start_mono}:0});
    GP_Rules($s,$cfg,'arrival',$e,$now,$mono);
    $s->{last_trip}=$s->{trip} if $s->{trip};
    delete $s->{trip};
    GP_Home($s,$cfg,$e->{time});
}

# GP_Home: Set Home status and clear obsolete return and absence context.
sub GP_Home {
    my ($s,$cfg,$time)=@_;
    my ($home)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{home}//[]};
    # Return makes distant memberships obsolete, but is not their exit event.
    # Keep overlapping/home memberships so another Home webhook is no new visit.
    if (GP_HasGeometry($home)) {
        for my $name (keys %{$s->{members}//{}}) {
            my $zone=$cfg->{zones}{$name};
            delete $s->{members}{$name} if GP_HasGeometry($zone)
                && GP_Distance($home,$zone)>$home->{radius}+$zone->{radius};
        }
    }
    $s->{phase}='home';
    $s->{location}='home';
    my $boundary=($s->{position_time}//0)>$time ? $s->{position_time}:$time;
    $s->{boundary}=$boundary if $boundary>$s->{boundary};
    delete @{$s}{qw(approach automotive conflict)};
    $s->{desired_status}='home';
    GP_ResetNegative($s,$boundary);
}

# GP_CheckClock: Revoke permissions when wall and monotonic clocks diverge beyond tolerance.
sub GP_CheckClock {
    my ($s,$cfg,$now,$mono)=@_;
    if (abs(($now-$s->{wall})-($mono-$s->{mono}))>$cfg->{future_tolerance}) {
        delete @{$s}{qw(trip arrival approach automotive motion motion_time position_time desired_status resume_event_floor)};
        $s->{phone}=GP_NewPhone(GP_UsesSource($cfg->{sourceMode},'phone'));
        $s->{zones}={}; $s->{members}={}; $s->{phase}='unknown'; $s->{boundary}=0; $s->{start}=$now;
        GP_RevokeOutputs($s); $s->{generation}.=':clock';
        GP_Trace($s,$now,'clock discontinuity; permissions revoked');
    }
    $s->{wall}=$now; $s->{mono}=$mono;
}

# GP_Contradiction: Check whether two simultaneous Geo observations are geometrically incompatible.
sub GP_Contradiction {
    my ($a,$b,$cfg)=@_;
    return 0 unless $a->{time}==$b->{time};
    return $a->{entry}!=$b->{entry} if $a->{zone} eq $b->{zone};
    my ($az,$bz)=map {$cfg->{zones}{$_->{zone}}} ($a,$b);
    return 0 unless GP_HasGeometry($az) && GP_HasGeometry($bz);
    my $dist=GP_Distance($az,$bz);
    return 1 if $a->{entry} && $b->{entry} && $dist>$az->{radius}+$bz->{radius};
    return 1 if !$a->{entry} && $b->{entry} && $dist+$bz->{radius}<=$az->{radius};
    return 1 if $a->{entry} && !$b->{entry} && $dist+$az->{radius}<=$bz->{radius};
    return 0;
}

# GP_BatchConflict: Detect conflicts among fresh Geo observations with equal timestamps.
# Geometry has already kept these observations in chronological order. Only
# equal observation times can contradict each other; freshness is checked once
# per event rather than again for every pair in the complete batch.
sub GP_BatchConflict {
    my ($s,$cfg,$events,$now)=@_;
    my @same_time;
    for my $e (@$events) {
        next unless GP_Fresh($cfg,$e,$now) && GP_AfterStart($s,$cfg,$e)
            && $e->{time}>=($s->{position_time}//0);
        @same_time=() if @same_time && $same_time[0]{time}!=$e->{time};
        for my $previous (@same_time) {
            return 1 if GP_Contradiction($previous,$e,$cfg);
        }
        push @same_time,$e;
    }
    return 0;
}

# GP_ProcessPhone: Apply phone observations, historical revocations, and status-only returns.
sub GP_ProcessPhone {
    my ($s,$cfg,$e,$now,$mono)=@_;
    # Historical presence cannot authorize a current arrival. It may still
    # disprove an older restored departure or a specific phone qualification.
    return GP_Trace($s,$now,'phone observation belongs to previous session')
        unless ($e->{generation}//'') eq $s->{generation};
    if ($e->{kind} eq 'phone_absent') {
        my $p=$s->{phone};
        return GP_Trace($s,$now,'phone absence qualification revoked') unless ($e->{negative_generation}//-1)==($p->{negative_generation}//0);
        return GP_Trace($s,$now,'phone absence contradicted by presence') if $e->{revoked};
        # Continuity may begin after Home exit while its held source values are
        # older. Keep both times; polling must not rewrite an observation date.
        my $since=$e->{negative_wall};
        my $time=$e->{qualified_at};
        return GP_Trace($s,$now,'phone absence older than current boundary')
            if defined($p->{negative_after}) && $e->{time}<=$p->{negative_after};
        # Keep the source observation time. After 180 s of qualification its age
        # may exceed action_max_age; this event never invokes action rules.
        if ($cfg->{geometry_ready} && $s->{trip} && !$s->{trip}{armed} && defined($s->{trip}{home_exit})
            && $since>=$s->{trip}{home_exit}) {
            my $t=$s->{trip};
            $t->{armed}=1; $t->{away_time}=$e->{negative_wall}; $t->{away_mono}=$e->{negative_since};
            $t->{away_reason}=$GP_PHONE_DEPARTURE_REASON;
            $t->{phone_qualification}=$e;
        }
        my $changed=$s->{phase} ne 'away' ? 1:0;
        GP_CancelArrival($s,$now,'new phone absence');
        # Further samples after completion do not supersede a return between
        # that completion and this poll. The source date itself stays intact.
        my $position=$e->{time}<$time ? $e->{time}:$time;
        if (!defined($s->{position_time}) || $position>$s->{position_time}) {
            $s->{checkpoint_dirty}=1; $s->{position_time}=$position;
        }
        $s->{phase}='away'; $s->{desired_status}='absent';
        return GP_Trace($s,$now,'phone absence qualified',{changed=>$changed,departure_armed=>$s->{trip} && $s->{trip}{armed} ? 1:0});
    }
    return unless $e->{kind} eq 'phone_present' || $e->{kind} eq 'phone_snapshot';
    my $snapshot=$e->{kind} eq 'phone_snapshot';
    my $fresh=!$snapshot && GP_Fresh($cfg,$e,$now);
    my $current=!$snapshot && GP_AfterStart($s,$cfg,$e);
    my $trip=$s->{trip}//$s->{last_trip};
    my $departure=GP_DepartureTime($trip);
    my $position=$s->{position_time}//0;
    my $limit=defined($departure) && $departure>$position ? $departure:$position;
    my $veto=!$snapshot && $trip && $trip->{armed} && ($s->{phone}{latest}//0)==$e->{time} && GP_PhoneVeto($s,$cfg,$limit);
    my $proof=$trip ? $trip->{phone_qualification}:undef;
    my $positive=$e->{positive_time}//$e->{time};
    my $contradicts=$proof && $positive<$proof->{qualified_at};
    my $restored=$snapshot && $trip && defined($s->{resume_event_floor}) && $s->{resume_event_floor}==$s->{start}
        && ($trip->{away_time}//$s->{start})<$s->{start} && defined($departure) && $e->{time}>=$departure;
    # Valid presence can disprove departure after its action budget expired.
    # A fresh actual return retains the normal arrival path and its permissions.
    my $revoke=$trip && defined($departure) && $e->{time}<=$now
        && ($restored || $contradicts || ($current && ($e->{time}<$departure
            ? $veto
            : (!$trip->{armed} || !$fresh || !GP_AwayLongEnough($cfg,$trip,$e,$mono)
                || (!$e->{arrival} && ($e->{time}>=$position || $veto))))));
    if ($revoke) {
        delete @{$s}{qw(trip last_trip automotive motion motion_time)};
        GP_CancelArrival($s,$now,'local phone presence revoked departure');
        GP_RevokeOutputs($s);
        if ($e->{time}>=$position) {
            $s->{position_time}=$e->{time}; GP_Home($s,$cfg,$e->{time});
        } else {
            GP_ResetNegative($s,$e->{time});
            $s->{phase}='away' if $s->{phase} eq 'returning' || $s->{phase} eq 'leaving';
        }
        GP_Trace($s,$now,!$trip->{armed} ? 'pending Home departure revoked by newer phone presence'
            : !$e->{arrival} ? 'continuous local presence; departure revoked':'local phone presence; departure revoked');
        return;
    }
    if ($snapshot) {
        return GP_Trace($s,$now,'startup phone snapshot superseded') if defined($s->{position_time}) || $s->{trip};
        $s->{phase}='home'; $s->{location}='home'; $s->{desired_status}='home';
        $s->{position_time}=$s->{start};
        GP_ResetNegative($s,$s->{start});
        return GP_Trace($s,$now,'held phone snapshot; status only');
    }
    return GP_Trace($s,$now,'event too old or future') unless $fresh && $e->{time}<=$now;
    return GP_Trace($s,$now,'event precedes session boundary') unless $current;
    return GP_Trace($s,$now,'duplicate event') if $e->{key} && $s->{seen}{$e->{key}};
    GP_RememberEvent($s,$e);
    return GP_Trace($s,$now,'observation older than current position') if $e->{time}<$position;
    $s->{position_time}=$e->{time};
    return GP_Arrive($s,$cfg,$e,$now,$mono);
}

# GP_Process: Apply one observation to travel, membership, motion, and action-planning state.
sub GP_Process {
    my ($s,$cfg,$e,$now,$mono)=@_;
    # Keep the cause on every decision made for this observation. Dynamic scope
    # prevents a later timer or actuator result from inheriting an old source.
    local $s->{trace_context}={source=>$e->{kind},zone=>$e->{zone}};
    $s->{intents}=[];
    return GP_Trace($s,$now,'observation source disabled by sourceMode')
        if ($e->{kind} eq 'geo' && !GP_UsesSource($cfg->{sourceMode},'geo'))
            || ($e->{kind} =~ /^phone_/ && !GP_UsesSource($cfg->{sourceMode},'phone'));
    $s->{last_observed}=$e->{time}; $s->{last_received}=$e->{received};
    $s->{last_key}=$e->{key}; $s->{config_revision}=GP_ConfigRevision($cfg);
    $e->{received_mono}//=$mono-($now-$e->{received});
    GP_CheckClock($s,$cfg,$now,$mono);
    GP_Trace($s,$now,'observation received',{diagnostic_only=>1,source=>$e->{kind},zone=>$e->{zone},entry=>$e->{entry},
        motion=>$e->{motion},zone_position=>$e->{zone_position},current_position=>$e->{current_position}});
    return GP_ProcessPhone($s,$cfg,$e,$now,$mono) if $e->{kind} =~ /^phone_/;
    return GP_Trace($s,$now,'event too old or future') unless GP_Fresh($cfg,$e,$now);
    return GP_Trace($s,$now,'event precedes session boundary') unless GP_AfterStart($s,$cfg,$e);
    if ($e->{key}) {
        if ($s->{seen}{$e->{key}}) {
            return if GP_EnrichDuplicate($s,$cfg,$e,$now,$mono);
            return GP_Trace($s,$now,'duplicate event');
        }
        GP_RememberEvent($s,$e);
    }
    if ($e->{time}<($s->{position_time}//0)) {
        my $p=$s->{arrival};
        # An older exit can revoke approach evidence without rewinding position.
        # An exit before the first Home keeps that Home's receipt anchor; an
        # exit during its wait requires a new wait from a later Home entry.
        if (GP_InterruptsArrival($s,$cfg,$e)) {
            my $revoked=defined($s->{motion_time}) && $s->{motion_time}<=$e->{time};
            delete @{$s}{qw(motion motion_time)} if $revoked;
            if (defined($s->{automotive}) && $s->{automotive}<=$e->{time}) {
                delete $s->{automotive}; $revoked=1;
            }
            $s->{checkpoint_dirty}=1 if $revoked;
            if ($p && $e->{time}<$p->{event}{time}) {
                $p->{origin_time}=$p->{event}{time};
                GP_UpdateArrivalMotion($s,$cfg,$p,$now,$p->{motion_evaluated_at}) if $revoked;
            } else {
                my $latest=$p ? $p->{latest_home}:undef;
                GP_CancelArrival($s,$now,'delayed exit interrupted arrival section');
                if ($latest && $latest->{time}>$e->{time}) {
                    GP_BeginArrival($s,$cfg,$latest,$now,$mono);
                } else {
                    $s->{phase}='away'; $s->{desired_status}='absent';
                }
            }
        }
        return GP_Trace($s,$now,'observation older than current position');
    }
    return unless $e->{kind} eq 'geo';
    my $zone=$cfg->{zones}{$e->{zone}} or return;
    return GP_GeometrySync($s,$cfg,$e,$now) unless $cfg->{geometry_ready} && GP_HasGeometry($zone);
    my $previous=$s->{zones}{$e->{zone}};
    return GP_Trace($s,$now,'older zone observation') if $previous && $e->{time}<$previous->{time};
    for my $name (keys %{$s->{zones}}) {
        if (GP_Contradiction($e,{%{$s->{zones}{$name}},zone=>$name},$cfg)) {
            $s->{conflict}=1; delete $s->{trip}; GP_CancelArrival($s,$now,'contradictory locations');
            GP_RevokeOutputs($s);
            return GP_Trace($s,$now,'contradictory locations at same time');
        }
    }
    return GP_Trace($s,$now,'event before completed arrival') if $e->{time}<=$s->{boundary};
    # Accepted Geo observations update the saved position, memberships and trip.
    # Rejected events and unchanged duplicates never reach this mutation path.
    $s->{checkpoint_dirty}=1;
    delete $s->{conflict};
    my $previous_position=$s->{position_time};
    $s->{position_time}=$e->{time};
    my $role=$zone->{role}; $e->{role}=$role;
    # Geometrically disjoint or nested contradictory older observations are stale.
    for my $other (keys %{$s->{zones}}) {
        next if $other eq $e->{zone};
        my $v=$s->{zones}{$other}; my $oz=$cfg->{zones}{$other} or next;
        next if $v->{time}>=$e->{time};
        next unless GP_HasGeometry($oz);
        my $dist=GP_Distance($zone,$oz);
        if (($e->{entry} && $dist>$zone->{radius}+$oz->{radius})
            || (!$e->{entry} && $dist+$oz->{radius}<=$zone->{radius})) { $v->{entry}=0; }
    }
    $s->{zones}{$e->{zone}}={entry=>$e->{entry},time=>$e->{time},role=>$role};
    $s->{location}=$e->{entry} ? $zone->{label} : 'underway';
    my ($home)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{home}//[]};
    my ($outer)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{outer}//[]};
    my $far = GP_HasGeometry($home)
        && GP_Distance($zone,$home)>$zone->{radius}+$home->{radius}+$cfg->{departure_margin};
    my $remote = ($role eq 'outer' && !$e->{entry})
        || (GP_HasGeometry($outer) && GP_Distance($zone,$outer)>$zone->{radius}+$outer->{radius});
    GP_CancelArrival($s,$now,'Home or surrounding area exited')
        if !$e->{entry} && $role =~ /\A(?:home|approach|outer)\z/;
    if (!$e->{entry} && $role eq 'home') {
        GP_LeaveHome($s,$cfg,$e,$mono);
    }
    my $area_exit=!$e->{entry} && ($role eq 'approach' || $role eq 'outer');
    # Without independent indoor sensors, a near-identical surrounding circle
    # cannot provide the extra distance evidence. Use its nearest boundary.
    if ($area_exit && $cfg->{sourceMode} eq 'geofency_only'
        && $zone->{radius}-GP_Distance($zone,$home)-$home->{radius}<=$cfg->{departure_margin}) {
        $area_exit=0;
        GP_Trace($s,$now,'departure area too close to Home; distance evidence required');
    }
    if ($area_exit || $far) {
        return unless GP_Arm($s,$cfg,$e,$now,$mono,$remote ? 'remote':'local',$previous_position);
        $s->{desired_status}='absent' if $s->{phase} eq 'away';
    }
    if (!$e->{entry} && ($role eq 'approach' || $role eq 'home')) {
        delete @{$s}{qw(automotive motion motion_time)};
    }
    if ($e->{entry} && ($role eq 'home' || $role eq 'approach')) {
        GP_ResetNegative($s,$e->{time});
        # Missing/unknown motion and stationary supply no new transport evidence.
        # Keep the last useful observation and its ORIGINAL time in this section;
        # an empty Home payload must neither erase walking nor refresh its TTL.
        if (($e->{motion}//'') =~ /\A(?:automotive|walking|running|cycling)\z/) {
            $s->{motion}=$e->{motion}; $s->{motion_time}=$e->{time};
            $s->{automotive}=$e->{time} if $e->{motion} eq 'automotive';
        }
    }
    for my $event (GP_LocationEvents($s,$cfg,$e)) {
        GP_Rules($s,$cfg,$e->{entry}?'enter':'exit',$event,$now,$mono);
    }
    if ($e->{entry} && ($role eq 'home' || $role eq 'approach')) {
        if ($role eq 'home' || $s->{arrival}) { GP_BeginArrival($s,$cfg,$e,$now,$mono); }
        elsif ($s->{trip} && $s->{trip}{armed}) {
            $s->{phase}='returning'; $s->{approach}={key=>$e->{key},origin_time=>$e->{time},mono=>$mono};
        }
    }
    GP_Trace($s,$now,'zone observation processed',{diagnostic_only=>1,zone=>$e->{zone},entry=>$e->{entry},
        zone_label=>$zone->{label},changed=>!$previous || $previous->{entry}!=$e->{entry} ? 1:0});
    return;
}

# GP_PhoneSamples: Read PRESENCE sources with their timestamps and health information.
sub GP_PhoneSamples {
    my ($cfg,$now)=@_;
    return {} unless GP_UsesSource($cfg->{sourceMode},'phone');
    my %samples;
    for my $p (@{$cfg->{proxies}}) {
        my $d=$defs{$p}//{};
        my $interval=$d->{INTERVAL_NORMAL};
        unless (defined $interval) { my @def=split /\s+/,$d->{DEF}//''; $interval=$def[3]//60; }
        $interval=60 unless GP_Number($interval) && $interval>0;
        my $present=$d->{INTERVAL_PRESENT}//$interval;
        $interval=$present if GP_Number($present) && $present>$interval;
        my $state=GP_Read($p,'state','unknown');
        my $value=GP_Read($p,'presence','unknown');
        my $t=GP_ReadingTime($p,'presence');
        my $healthy=$state =~ /\A(?:present|absent)\z/ && $state eq $value && !GP_Attr($p,'disable',0)
            && !(($d->{helper}//{})->{DISABLED})
            && ($d->{STATE}//'') !~ /\A(?:disconnected|disabled|error|timeout)\z/i;
        $samples{$p}={value=>$value,time=>$t,ttl=>2*$interval+30,healthy=>$healthy?1:0};
    }
    return \%samples;
}

# GP_PhoneEvidence: Classify samples into presence, full absence, and return-time evidence.
sub GP_PhoneEvidence {
    my ($s,$cfg,$samples,$now)=@_;
    my $p=$s->{phone};
    my $state_mode=($cfg->{phoneSignalMode}//'state') eq 'state';
    my ($latest,$observed,$arrival_time);
    my $departure=GP_DepartureTime($s->{trip});
    my $new_positive;
    my $negative=0;
    # Track each source separately so a newer positive cannot hide an older, newly
    # received contradiction from another source.
    for my $name (@{$cfg->{proxies}}) {
        my $v=$samples->{$name}//{};
        my $t=$v->{time};
        unless ($v->{healthy} && defined($t) && $t<=$now
            && ($state_mode || ($t>$s->{start} && $now-$t<=($v->{ttl}//0)))
            && ($v->{value}//'') =~ /\A(?:present|absent)\z/) {
            # Reconnection alone cannot restore an invalidated old sample.
            $p->{invalidated}{$name}=$now;
            next;
        }
        next if defined($p->{invalidated}{$name}) && $t<=$p->{invalidated}{$name};
        next if $t<($p->{samples}{$name}//0);
        delete $p->{invalidated}{$name};
        if ($v->{value} eq 'present') {
            $latest=$t if !defined($latest) || $t>$latest;
            if ($t>($p->{samples}{$name}//0)) {
                $new_positive=$t if !defined($new_positive) || $t<$new_positive;
                $arrival_time=$t if defined($departure) && $t>=$departure
                    && (!defined($arrival_time) || $t<$arrival_time);
            }
        } else {
            $negative++;
            $observed=$t if !defined($observed) || ($state_mode ? $t>$observed:$t<$observed);
        }
        $p->{samples}{$name}=$t;
    }
    # A positive wins; absence requires every configured source. Return only
    # the times needed by continuity, without copying or sorting sample lists.
    return ($latest,$new_positive,$negative==@{$cfg->{proxies}} ? $observed:undef,$arrival_time);
}

# GP_Phone: Advance phone continuity and return any resulting presence or absence observation.
# State sources latch present/absent until a change or fault. Measurement sources
# additionally require periodic measurements and a TTL. Neither contract refreshes
# the source timestamp just because GeoPresence polls the reading.
sub GP_Phone {
    my ($s,$cfg,$samples,$now,$mono)=@_;
    return unless GP_UsesSource($cfg->{sourceMode},'phone');
    my $p=$s->{phone};
    my $state_mode=($cfg->{phoneSignalMode}//'state') eq 'state';
    my ($latest,$new_positive,$observed,$arrival_time)=GP_PhoneEvidence($s,$cfg,$samples,$now);
    if (defined($latest)) {
        if (defined($new_positive)) {
            # Invalidate the records themselves, not a global generation: an
            # actual return AFTER a completed interval keeps that interval valid.
            for my $event (@{$s->{queued_phones}//[]}) {
                next unless ref($event) eq 'HASH' && $event->{kind} eq 'phone_absent' && !$event->{revoked};
                $event->{revoked}=1 if $new_positive<$event->{qualified_at};
            }
        }
        # The person may move between rooms, with several or temporarily no
        # sensors detecting them. Only a qualified absence or a long observation
        # gap ends continuity; a short handover is never a new arrival.
        my $long_gap=defined($p->{missing_since}) && $mono-$p->{missing_since}>=$cfg->{phone_absence_window};
        my $arrival=($p->{state} eq 'absent' || !$p->{ever_present} || $long_gap) ? 1:0;
        my $old_state=$p->{state};
        $p->{state}='present'; $p->{health}=$state_mode?'held':'fresh'; $p->{latest}=$latest; $p->{ever_present}=1;
        GP_ResetNegative($s,undef);
        delete $p->{missing_since};
        return unless defined($new_positive);
        # An active trip keeps its first relevant return for freshness and budgets.
        # Later status changes use the latest source, independent of completed trips.
        my $time=$arrival_time//$latest;
        my $snapshot=$state_mode && $time<=$s->{start};
        my $proof=($s->{last_trip}//{})->{phone_qualification};
        return unless $snapshot || $s->{phase} ne 'home' || $s->{trip}
            || ($proof && $new_positive<$proof->{qualified_at});
        my $event={kind=>$snapshot ? 'phone_snapshot':'phone_present',time=>$time,
            received=>$now,received_mono=>$mono,generation=>$s->{generation}};
        $event->{positive_time}=$new_positive if $new_positive<$time;
        @{$event}{qw(arrival key)}=($arrival,'phone:'.$time.':'.$old_state) unless $snapshot;
        return $event;
    }
    $p->{missing_since}//=$mono;
    if (defined($observed)) {
        if (defined($p->{negative_after}) && $observed<=$p->{negative_after}) {
            GP_ResetNegative($s,undef);
        } else {
            return if $p->{qualified};
            $p->{negative_since}//=$mono;
            $p->{negative_wall}//=$now;
            my $renewed=1;
            unless ($state_mode) {
                # Retain only sources still awaiting their first renewal. Later
                # identical measurements cannot move a satisfied deadline.
                my $pending=$p->{negative_first}//={map {$_=>$samples->{$_}{time}} @{$cfg->{proxies}}};
                for my $name (keys %$pending) {
                    my $time=$samples->{$name}{time};
                    next if $time<=$pending->{$name};
                    delete $pending->{$name};
                    $p->{negative_renewed_at}=$time if !defined($p->{negative_renewed_at}) || $time>$p->{negative_renewed_at};
                    my $source_mono=$mono-($now-$time);
                    $p->{negative_renewed_mono}=$source_mono
                        if !defined($p->{negative_renewed_mono}) || $source_mono>$p->{negative_renewed_mono};
                }
                $renewed=!keys %$pending;
            }
            if ($renewed && $mono-$p->{negative_since}>=$cfg->{phone_absence_window}) {
                $p->{state}='absent'; $p->{health}=$state_mode?'held':'fresh';
                $p->{qualified}=1;
                my $qualified_at=$p->{negative_wall}+$cfg->{phone_absence_window};
                my $qualified_mono=$p->{negative_since}+$cfg->{phone_absence_window};
                unless ($state_mode) {
                    $qualified_at=$p->{negative_renewed_at} if $p->{negative_renewed_at}>$qualified_at;
                    $qualified_mono=$p->{negative_renewed_mono} if $p->{negative_renewed_mono}>$qualified_mono;
                }
                return {kind=>'phone_absent',time=>$observed,received=>$now,received_mono=>$mono,generation=>$s->{generation},
                    qualified_at=>$qualified_at,qualified_mono=>$qualified_mono,
                    negative_generation=>$p->{negative_generation}//0,
                    negative_wall=>$p->{negative_wall},negative_since=>$p->{negative_since}};
            }
        }
    } else {
        GP_ResetNegative($s,undef);
    }
    if ($p->{state} eq 'present' && $mono-$p->{missing_since}<$cfg->{phone_absence_window}) {
        $p->{health}='handover';
    } else {
        $p->{state}='unknown' unless $p->{state} eq 'absent';
        $p->{health}='unknown';
    }
    return;
}

# GP_TickState: Advance departure grace and expire approach and display data.
sub GP_TickState {
    my ($s,$cfg,$now,$mono)=@_;
    GP_CheckClock($s,$cfg,$now,$mono);
    if ($s->{phase} eq 'leaving' && $s->{trip} && defined($s->{trip}{leave_mono})
        && $mono-$s->{trip}{leave_mono}>=$cfg->{departure_grace}) {
        if (!GP_UsesSource($cfg->{sourceMode},'phone') || $s->{phone}{state} ne 'present') { $s->{phase}='away'; $s->{desired_status}='absent'; }
    }
    if ($s->{approach} && $mono-$s->{approach}{mono}>=$cfg->{approach_timeout}) {
        $s->{checkpoint_dirty}=1 if grep {exists $s->{$_}} qw(automotive motion motion_time);
        delete @{$s}{qw(approach automotive motion motion_time)};
        $s->{phase}='away' if $s->{trip};
    }
    for my $name (keys %{$s->{zones}}) {
        my $z=$s->{zones}{$name};
        if ($now-$z->{time}>$cfg->{zone_display_max_age}) {
            if ($z->{entry}) { $z->{entry}=0; $s->{checkpoint_dirty}=1; }
            if (($s->{location}//'') ne 'unknown' && ($s->{location}//'') eq $cfg->{zones}{$name}{label}) {
                $s->{location}='unknown'; $s->{checkpoint_dirty}=1;
            }
        }
    }
    return;
}

# GP_HTTPConfigError: Return the first listener configuration error, or undef for a valid setup.
sub GP_HTTPConfigError {
    my ($c)=@_;
    my $port=GP_Attr($c->{NAME},'webhookPort',$GP_DEFAULT_WEBHOOK_PORT);
    return 'webhookPort must be an integer from 1024 to 65535'
        unless $port =~ /\A[0-9]{4,5}\z/ && $port>=1024 && $port<=65535;
    return 'webhookPath must be a simple path component'
        unless GP_Attr($c->{NAME},'webhookPath','geopresence') =~ /\A[a-zA-Z][a-zA-Z0-9_-]*\z/;
    my $address=GP_Attr($c->{NAME},'webhookBindAddress','127.0.0.1');
    return 'webhookBindAddress must be a concrete IPv4 address; no wildcard or hostname' unless GP_IPv4($address);
    return 'Network binding requires explicit webhookAllowedPeers'
        if $address !~ /\A127\./ && !length(GP_Attr($c->{NAME},'webhookAllowedPeers',''));
    return 'webhookAllowedPeers must list 1..16 distinct IPv4 addresses separated by commas'
        unless GP_PeerListValid(GP_Attr($c->{NAME},'webhookAllowedPeers','127.0.0.1'));
    return;
}

# GP_CloseHTTPClient: Unregister and close a transient HTTP client.
# This listener never enters FHEMWEB or FHEM's command parser. FHEMWEB dispatches
# XHR/cmd before FWEXT authentication, even on an otherwise restricted URL.
# Transient selectlist entries use the core's direct callbacks, not FHEM devices.
sub GP_CloseHTTPClient {
    my ($h)=@_;
    delete $selectlist{$h->{NAME}};
    my $c=$defs{$h->{OWNER}};
    delete $c->{helper}{gp_http}{clients}{$h->{NAME}} if $c && $c->{helper}{gp_http};
    close(delete $h->{CD}) if $h->{CD};
    delete $h->{FD};
}

# GP_StopHTTP: Close the dedicated listener and all of its pending clients.
sub GP_StopHTTP {
    my ($c)=@_;
    my $http=delete $c->{helper}{gp_http};
    delete $c->{helper}{gp_http_error};
    return unless $http;
    GP_CloseHTTPClient($_) for values %{$http->{clients}};
    my $server=$http->{server};
    delete $selectlist{$server->{NAME}};
    close(delete $server->{CD}) if $server->{CD};
    delete $server->{FD};
}

# GP_OpenHTTP: Bind the nonblocking webhook listener and register its FHEM callback.
sub GP_OpenHTTP {
    my ($c,$port)=@_;
    my $address=GP_Attr($c->{NAME},'webhookBindAddress','127.0.0.1');
    my $peers=GP_Attr($c->{NAME},'webhookAllowedPeers','127.0.0.1');
    my $socket=IO::Socket::INET->new(LocalAddr=>$address,LocalPort=>$port,
        Proto=>'tcp',Listen=>16,ReuseAddr=>1,Blocking=>0);
    return "Cannot listen on $address:$port: $!" unless $socket;
    my $name='GeoPresenceHTTP:'.$c->{NAME};
    my $server={NAME=>$name,OWNER=>$c->{NAME},CD=>$socket,FD=>fileno($socket),directReadFn=>\&GP_AcceptHTTP};
    $c->{helper}{gp_http}={port=>$port,address=>$address,allowed_peers=>$peers,
        peers=>{map {$_=>1} GP_List($peers)},server=>$server,clients=>{}};
    $selectlist{$name}=$server;
    GP_Log($c,3,'listener_started',{reason=>"Listening on $address:$port"});
    return;
}

# GP_EnsureHTTP: Maintain listener configuration and close clients whose deadlines expired.
sub GP_EnsureHTTP {
    my ($c)=@_;
    if (my $error=GP_HTTPConfigError($c)) { GP_StopHTTP($c); return $error; }
    my $port=GP_Attr($c->{NAME},'webhookPort',$GP_DEFAULT_WEBHOOK_PORT);
    my $http=$c->{helper}{gp_http};
    GP_StopHTTP($c) if $http && ($http->{port} != $port
        || ($http->{address}//'') ne GP_Attr($c->{NAME},'webhookBindAddress','127.0.0.1')
        || ($http->{allowed_peers}//'') ne GP_Attr($c->{NAME},'webhookAllowedPeers','127.0.0.1'));
    unless ($c->{helper}{gp_http}) {
        my $error=GP_OpenHTTP($c,$port);
        if ($error) { $c->{helper}{gp_http_error}=$error; return $error; }
        delete $c->{helper}{gp_http_error};
    }
    for my $client (values %{$c->{helper}{gp_http}{clients}}) {
        GP_CloseHTTPClient($client) if GP_Mono()>=$client->{deadline};
    }
    return;
}

# GP_AcceptHTTP: Accept a bounded number of clients from explicitly allowed socket peers.
sub GP_AcceptHTTP {
    my ($server)=@_;
    my $c=$defs{$server->{OWNER}};
    return unless $c && $c->{helper}{gp_http};
    my $clients=$c->{helper}{gp_http}{clients};
    for (1..16) {
        my $socket=$server->{CD}->accept() or last;
        # Bound memory and work per callback; excess clients retry through Geofency.
        # Trust only the actual socket peer, never X-Forwarded-For/X-Real-IP.
        if (keys(%$clients)>=16 || !$c->{helper}{gp_http}{peers}{$socket->peerhost}) { close $socket; next; }
        $socket->blocking(0);
        my $name=$server->{NAME}.'.'.fileno($socket);
        my $h={NAME=>$name,OWNER=>$c->{NAME},CD=>$socket,FD=>fileno($socket),
            input=>'',deadline=>GP_Mono()+10,directReadFn=>\&GP_ReadHTTP};
        $clients->{$name}=$h;
        $selectlist{$name}=$h;
    }
}

# GP_HTTPFrame: Parse one bounded HTTP request without invoking FHEM's command parser.
# Parse exactly one bounded request, without decoding the URL or combining it
# with the body. No transfer coding, duplicate headers, folding or pipelining.
# An empty return means that more bytes are needed; errors carry an HTTP status.
sub GP_HTTPFrame {
    my ($input)=@_;
    my $end=index($input,"\r\n\r\n");
    return (undef,431,'Headers too large') if ($end<0 && length($input)>8192) || $end>8188;
    return if $end<0;
    my ($line,@lines)=split /\r\n/,substr($input,0,$end);
    return (undef,400,'Invalid request line') unless defined($line)
        && $line =~ m{\A([A-Z]+) ([\x21-\x7e]+) HTTP/1\.([01])\z};
    my ($method,$path,$version)=($1,$2,$3);
    my %headers;
    for my $header (@lines) {
        return (undef,400,'Invalid header') unless $header =~ /\A([A-Za-z0-9][A-Za-z0-9-]*):[ \t]*([\x20-\x7e\t]*)\z/;
        my ($key,$value)=(lc($1),$2);
        $value =~ s/[ \t]+\z//;
        return (undef,400,'Duplicate header') if exists $headers{$key};
        $headers{$key}=$value;
    }
    return (undef,400,'Host required') if $version eq '1' && !length($headers{host}//'');
    return (undef,400,'Transfer-Encoding unsupported') if exists $headers{'transfer-encoding'};
    return (undef,417,'Expect unsupported') if exists $headers{expect};
    return (undef,411,'Content-Length required') if $method eq 'POST' && !exists $headers{'content-length'};
    my $length=$headers{'content-length'}//0;
    return (undef,400,'Invalid Content-Length') unless $length =~ /\A[0-9]{1,6}\z/;
    return (undef,413,'Request too large') if $length>16384;
    my $received=length($input)-$end-4;
    return (undef,400,'Only one request per connection allowed') if $received>$length;
    return if $received<$length;
    return ({method=>$method,path=>$path,headers=>\%headers,body=>substr($input,$end+4)});
}

# GP_HTTPResponse: Build a UTF-8 plain-text response with the required status headers.
sub GP_HTTPResponse {
    my ($status,$text)=@_;
    my %labels=(200=>'OK',400=>'Bad Request',401=>'Unauthorized',403=>'Forbidden',404=>'Not Found',405=>'Method Not Allowed',
        411=>'Length Required',413=>'Content Too Large',415=>'Unsupported Media Type',417=>'Expectation Failed',
        422=>'Unprocessable Content',429=>'Too Many Requests',431=>'Request Header Fields Too Large',503=>'Service Unavailable');
    my $content=encode('UTF-8',$text."\n");
    return "HTTP/1.1 $status $labels{$status}\r\nContent-Type: text/plain; charset=utf-8\r\n"
        .'Content-Length: '.length($content)."\r\nCache-Control: no-store\r\nConnection: close\r\n"
        .($status==401 ? "WWW-Authenticate: Basic realm=\"GeoPresence\"\r\n" : '')
        .($status==405 ? "Allow: POST\r\n" : '')."\r\n".$content;
}

# GP_ReadHTTP: Read a nonblocking request and prepare its HTTP response.
sub GP_ReadHTTP {
    my ($h)=@_;
    return GP_CloseHTTPClient($h) if GP_Mono()>=$h->{deadline};
    my $count=sysread($h->{CD},my $bytes,4096);
    return if !defined($count) && ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR);
    return GP_CloseHTTPClient($h) unless $count;
    $h->{input}.=$bytes;
    my ($request,$status,$text)=GP_HTTPFrame($h->{input});
    if ($request) {
        ($status,$text)=GP_HTTP($defs{$h->{OWNER}},@$request{qw(method path headers body)});
    } elsif ($status) {
        GP_Log($defs{$h->{OWNER}},2,'http_frame_rejected',{status=>$status,reason=>$text});
    }
    return unless $status;
    delete $h->{input};
    delete $h->{directReadFn};
    $h->{output}=GP_HTTPResponse($status,$text);
    $h->{directWriteFn}=\&GP_WriteHTTP;
}

# GP_WriteHTTP: Flush a nonblocking response and close the completed connection.
sub GP_WriteHTTP {
    my ($h)=@_;
    return GP_CloseHTTPClient($h) if GP_Mono()>=$h->{deadline};
    local $SIG{PIPE}='IGNORE';
    my $count=syswrite($h->{CD},$h->{output});
    return if !defined($count) && ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR);
    return GP_CloseHTTPClient($h) unless $count;
    substr($h->{output},0,$count,'');
    GP_CloseHTTPClient($h) unless length $h->{output};
}

# GP_ClearCheckpoint: Persist an inactive checkpoint only when its diagnostic value changes.
sub GP_ClearCheckpoint {
    my ($r,$reason)=@_;
    my $d=$defs{$r} or return;
    my $value=$GP_CHECKPOINT_JSON->encode({version=>2,status=>'none',reason=>$reason});
    return if GP_Read($r,'gp_trip_checkpoint','') eq $value;
    setReadingsVal($d,'gp_trip_checkpoint',$value,POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now())));
}

# GP_ResumeRevision: Bind restart recovery to configuration, identities, and stored credentials.
sub GP_ResumeRevision {
    my ($c,$r,$cfg)=@_;
    # Geometry, rules, adapters and source contract are part of the cfg hash.
    # Bind identities and authentication too, without persisting credentials.
    return $cfg->{resume_revision} if defined $cfg->{resume_revision};
    my $revision=GP_ConfigRevision($cfg);
    my (undef,$auth)=GP_Auth($r);
    return $cfg->{resume_revision}=sha256_hex($GP_CHECKPOINT_JSON->encode({
        config=>$revision,controller=>$c->{NAME},resident=>$r,
        device=>lc(GP_Attr($r,'deviceId','')),user=>lc(GP_Attr($r,'webhookUser','')),
        auth=>sha256_hex($auth//''),roommate=>$cfg->{roommate}}));
}

# GP_Checkpoint: Persist qualified unfinished travel or clear evidence that is no longer valid.
sub GP_Checkpoint {
    my ($c,$r,$cfg,$s)=@_;
    my $rt=$c->{helper}{gp};
    # Invalidated evidence must also reach the state file while the listener is
    # down or a contradiction blocks outputs. Persistence is not an actuator.
    return unless $rt && GP_EffectiveMode($c,$r,0) eq 'active'
        && $rt->{prod}{$r} && $rt->{prod}{$r}==$s;
    my $t=$s->{trip};
    $cfg//=GP_Config($c,$r,0) if $t && $t->{armed} && !$s->{conflict};
    my $qualified=$t && $t->{armed} && !$s->{conflict} && GP_UsesSource($cfg->{sourceMode},'geo')
        && $cfg->{geometry_ready} && $s->{phase} =~ /\A(?:away|leaving|returning)\z/;
    my $trip=$qualified ? $t->{id}:'';
    if ($qualified && exists($s->{notify_seen})) {
        GP_CompactConsumption($cfg,$t,$s);
        $s->{checkpoint_dirty}=1;
    }
    # Persist only changed journey data. Always check qualification first so
    # revocations cannot be hidden by a clean marker. Also repair edited readings.
    return if defined($s->{checkpoint_trip}) && $s->{checkpoint_trip} eq $trip
        && (!$qualified || !$s->{checkpoint_dirty})
        && ($s->{checkpoint_value}//'') eq GP_Read($r,'gp_trip_checkpoint','');
    if ($qualified) {
        my $checkpoint={version=>2,status=>'qualified',saved_at=>GP_Now(),
            revision=>GP_ResumeRevision($c,$r,$cfg),
            trip=>{map {$_=>$t->{$_}} grep {exists $t->{$_}} @GP_CHECKPOINT_TRIP_FIELDS},
            state=>{map {$_=>$s->{$_}} grep {exists $s->{$_}}
                (@GP_CHECKPOINT_STATE_FIELDS,qw(action_visits action_last))}};
        my $value=eval {$GP_CHECKPOINT_JSON->encode($checkpoint)};
        if (defined($value) && length($value)<=65536) {
            setReadingsVal($defs{$r},'gp_trip_checkpoint',$value,
                POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now())));
        } else {
            GP_ClearCheckpoint($r,'Qualified trip checkpoint exceeds storage limit');
            GP_Trace($s,GP_Now(),'qualified trip could not be checkpointed',{source=>'checkpoint'});
        }
    } else { GP_ClearCheckpoint($r,'No unfinished qualified trip'); }
    $s->{checkpoint_dirty}=0;
    $s->{checkpoint_trip}=$trip;
    $s->{checkpoint_value}=GP_Read($r,'gp_trip_checkpoint','');
}

# GP_ResumeTrip: Restore validated unfinished travel without recreating old timers or commands.
sub GP_ResumeTrip {
    my ($c,$r,$cfg,$s)=@_;
    my $raw=GP_Read($r,'gp_trip_checkpoint','');
    $s->{resume}={status=>'none',reason=>'No saved qualified trip'};
    return unless length($raw);
    my ($checkpoint,$trip,$state,$legacy);
    my ($now,$mono)=(GP_Now(),GP_Mono());
    my $error;
    {
        local $@;
        my $ok=eval {
            die "checkpoint too large\n" if length($raw)>65536;
            $checkpoint=$GP_CHECKPOINT_JSON->decode($raw);
            die "invalid checkpoint structure\n" unless ref($checkpoint) eq 'HASH'
                && !ref($checkpoint->{version}) && ($checkpoint->{version}//'') =~ /\A[12]\z/
                && !ref($checkpoint->{status}) && ($checkpoint->{status}//'') =~ /\A(?:qualified|none)\z/;
            $legacy=$checkpoint->{version}==1;
            if ($checkpoint->{status} eq 'qualified') {
                die "resident is not active\n" unless GP_EffectiveMode($c,$r,0) eq 'active';
                die "configuration or identity changed\n" unless $cfg->{geometry_ready}
                    && GP_UsesSource($cfg->{sourceMode},'geo')
                    && ($checkpoint->{revision}//'') eq GP_ResumeRevision($c,$r,$cfg);
                $trip=$checkpoint->{trip}; $state=$checkpoint->{state};
                die "invalid trip structure\n" unless ref($trip) eq 'HASH' && ref($state) eq 'HASH'
                    && !ref($trip->{armed}) && ($trip->{armed}//'') eq '1'
                    && !ref($trip->{scope}) && ($trip->{scope}//'') =~ /\A(?:local|remote)\z/
                    && defined($trip->{id}) && !ref($trip->{id}) && length($trip->{id})<=256
                    && $trip->{id} =~ /\A[A-Za-z0-9_.:\-]+\z/;
                # Accept persisted travel fields only; runtime queues and timers are not restorable.
                my %trip_keys=map {$_=>1} @GP_CHECKPOINT_TRIP_FIELDS;
                my %state_keys=map {$_=>1} (@GP_CHECKPOINT_STATE_FIELDS,
                    $legacy ? qw(notify_seen notify_order notify_last) : qw(action_visits action_last));
                die "unsupported checkpoint fields\n" if grep {!$trip_keys{$_}} keys %$trip;
                die "unsupported checkpoint fields\n" if grep {!$state_keys{$_}} keys %$state;
                die "invalid departure reason\n" if exists($trip->{away_reason})
                    && (ref($trip->{away_reason}) || length($trip->{away_reason}//'')>512);
                for my $time ($trip->{start},$trip->{away_time},$checkpoint->{saved_at}) {
                    die "invalid trip timestamp\n" unless GP_Number($time) && $time>0 && $time<=$now+$cfg->{future_tolerance};
                }
                die "inconsistent departure timestamps\n" if $trip->{away_time}<$trip->{start}
                    || $checkpoint->{saved_at}+$cfg->{future_tolerance}<$trip->{away_time};
                die "saved departure expired\n" if $now-$trip->{away_time}>$cfg->{trip_resume_max_age};
                for my $time (map {$trip->{$_}} grep {defined $trip->{$_}} qw(home_exit)) {
                    die "invalid Home exit\n" unless GP_Number($time) && $time>=$trip->{start}
                        && $time<=$checkpoint->{saved_at}+$cfg->{future_tolerance};
                }
                for my $key (qw(position_time boundary motion_time automotive)) {
                    next unless exists $state->{$key};
                    die "invalid observation timestamp\n" unless GP_Number($state->{$key}) && $state->{$key}>=0
                        && $state->{$key}<=$checkpoint->{saved_at}+$cfg->{future_tolerance};
                }
                die "invalid saved movement\n" if exists($state->{motion})
                    && ($state->{motion}//'') !~ /\A(?:unknown|stationary|walking|running|cycling|automotive)\z/;
                die "invalid saved location\n" if exists($state->{location})
                    && (ref($state->{location}) || length($state->{location}//'')>512);
                for my $key (qw(actions exits)) {
                    die "invalid trip history\n" if exists($trip->{$key}) && ref($trip->{$key}) ne 'HASH';
                }
                die "missing consumption state\n" if !$legacy && (ref($trip->{actions}) ne 'HASH'
                    || ref($state->{action_visits}) ne 'HASH' || ref($state->{action_last}) ne 'HASH');
                for my $ref (keys %{$trip->{exits}//{}}) {
                    my $time=$trip->{exits}{$ref};
                    die "invalid prior exit\n" unless ($ref =~ /\Alocation:(.+)\z/ && $cfg->{zones}{$1}
                        || $ref =~ /\Agroup:(.+)\z/ && $cfg->{groups}{$1})
                        && GP_Number($time) && $time>=$trip->{start}
                        && $time<=$checkpoint->{saved_at}+$cfg->{future_tolerance};
                }
                for my $key (qw(zones members)) {
                    die "invalid saved membership\n" if exists($state->{$key}) && ref($state->{$key}) ne 'HASH';
                    for my $name (keys %{$state->{$key}//{}}) {
                        my $v=$state->{$key}{$name};
                        die "invalid saved membership\n" unless $cfg->{zones}{$name} && ref($v) eq 'HASH'
                            && ($v->{entry}//'') =~ /\A[01]\z/ && GP_Number($v->{time}) && $v->{time}>0
                            && $v->{time}<=$checkpoint->{saved_at}+$cfg->{future_tolerance};
                    }
                }
                for my $key (qw(zone_visits group_visits),$legacy ? qw(notify_seen notify_last) : qw(action_visits action_last)) {
                    die "invalid saved counters\n" if exists($state->{$key}) && ref($state->{$key}) ne 'HASH';
                    for my $v (values %{$state->{$key}//{}}) {
                        die "invalid saved counter\n" unless GP_Number($v) && $v>=0;
                    }
                }
                for my $spec ([zone_visits=>'zones'],[group_visits=>'groups']) {
                    for my $name (keys %{$state->{$spec->[0]}//{}}) {
                        my $v=$state->{$spec->[0]}{$name};
                        die "invalid saved visit\n" unless exists($cfg->{$spec->[1]}{$name}) && $v==int($v);
                    }
                }
                if ($legacy) {
                    die "invalid notification history\n" if exists($state->{notify_order})
                        && (ref($state->{notify_order}) ne 'ARRAY' || @{$state->{notify_order}}>2000
                            || grep {!defined($_) || ref($_) || length($_)>512} @{$state->{notify_order}});
                    for my $key (keys %{$trip->{actions}//{}}) {
                        die "invalid consumed action\n" unless length($key)<=512
                            && GP_Number($trip->{actions}{$key}) && $trip->{actions}{$key}>0;
                    }
                    GP_CompactConsumption($cfg,$trip,$state);
                }
                my $slots=GP_ConsumptionSlots($cfg);
                for my $key (keys %{$trip->{actions}//{}}) {
                    die "invalid consumed action\n" unless exists($slots->{trip}{$key})
                        && GP_Number($trip->{actions}{$key}) && $trip->{actions}{$key}==1;
                }
                for my $key (keys %{$state->{action_visits}//{}}) {
                    my $slot=$slots->{visit}{$key}; my $v=$state->{action_visits}{$key};
                    die "invalid consumed visit\n" unless $slot && $v==int($v)
                        && $v<=(($state->{$slot->[0]}//{})->{$slot->[1]}//0);
                }
                die "invalid action cooldown\n" if grep {!exists $slots->{last}{$_}} keys %{$state->{action_last}//{}};
                # Later local presence overrides the saved absence, even if the checkpoint is valid.
                my $rrtime=GP_ReadingTime($cfg->{roommate},'state');
                die "a later ROOMMATE Home state superseded the departure\n" if defined($rrtime)
                    && $rrtime>=int($trip->{away_time}) && GP_Read($cfg->{roommate},'state','') =~ /\A(?:home|gotosleep|asleep|awoken)\z/;
                if (GP_UsesSource($cfg->{sourceMode},'phone')) {
                    my $samples=GP_PhoneSamples($cfg,$now);
                    die "a later local presence superseded the departure\n" if grep {
                        my $v=$samples->{$_}; $v->{healthy} && ($v->{value}//'') eq 'present'
                            && defined($v->{time}) && $v->{time}>=int($trip->{away_time}) && $v->{time}<=$now
                    } @{$cfg->{proxies}};
                }
            }
            1;
        };
        $error=$@ unless $ok;
    }
    if ($error) {
        $error =~ s/\s+\z//;
        $s->{resume}={status=>'rejected',reason=>$error};
        GP_ClearCheckpoint($r,'Restart recovery rejected: '.$error);
        GP_Trace($s,$now,'saved trip rejected: '.$error,{source=>'restart'});
        return;
    }
    return unless $checkpoint->{status} eq 'qualified';
    # Monotonic origins belong to the NEW process. Carry absolute evidence
    # times across reboot; never reuse a pending dwell timer or old queue.
    $s->{$_}=$state->{$_} for keys %$state;
    $s->{zones}{$_}{role}=$cfg->{zones}{$_}{role} for keys %{$s->{zones}};
    $s->{trip}=$trip;
    $s->{trip}{away_mono}=$mono-($now-$trip->{away_time});
    $s->{trip}{leave_mono}=$mono-($now-$trip->{home_exit}) if defined $trip->{home_exit};
    # Saved qualified data supplies a conservative return fence at saved_at.
    # Original departure/window checks remain; no collection or timer is resumed.
    $s->{trip}{phone_qualification}={qualified_at=>$checkpoint->{saved_at},
        qualified_mono=>$mono-($now-$checkpoint->{saved_at})}
        if ($trip->{away_reason}//'') eq $GP_PHONE_DEPARTURE_REASON;
    $s->{phase}='away';
    $s->{checkpoint_dirty}=$legacy ? 1:0;
    $s->{checkpoint_trip}=$trip->{id};
    $s->{checkpoint_value}=$raw;
    $s->{resume_event_floor}=$s->{start};
    $s->{resume}={status=>'restored',restored_at=>$now,saved_at=>$checkpoint->{saved_at},reason=>'Qualified unfinished trip restored'};
    GP_Trace($s,$now,'qualified unfinished trip restored; waiting for a new return',{source=>'restart'});
}

# GP_State: Return or initialize a resident context and attempt pending productive recovery.
sub GP_State {
    my ($c,$r,$debug,$cfg)=@_;
    my $rt=$c->{helper}{gp};
    my $pool=$debug ? 'debug':'prod';
    unless ($rt->{$pool}{$r}) {
        my $s=GP_NewState($rt->{resident_start}{$r}//$rt->{start},$rt->{resident_mono}{$r}//$rt->{mono},
            $rt->{epoch}.':'.$pool.':'.$r.':'.($rt->{resident_generation}{$r}//0),GP_Attr($r,'sourceMode','geofency_phone'));
        unless ($debug) {
            $s->{restored}={map {$_=>GP_Read($r,$_,'unknown')} qw(gp_phase gp_location gp_trip_id gp_door_result gp_garage_result)};
            for my $result (qw(door_result garage_result)) {
                $s->{$result}='uncertain' if $s->{restored}{'gp_'.$result} =~ /\A(?:pending|dispatch_started|shared)\z/;
            }
        }
        $rt->{$pool}{$r}=$s;
        GP_ResumeTrip($c,$r,$cfg//GP_Config($c,$r,0),$s) if !$debug && delete $rt->{resume_pending}{$r};
    }
    return $rt->{$pool}{$r};
}

# GP_Normalize: Validate decoded Geofency fields and return an internal observation or an error.
sub GP_Normalize {
    my ($c,$r,$cfg,$p,$now,$learning)=@_;
    return (undef,'Invalid device identifier') unless GP_Id($p->{device});
    my $device=lc($p->{device});
    my $expected=lc GP_Attr($r,'deviceId','');
    if ($learning) {
        my $learned=GP_Learned($c,$r);
        return (undef,'Learning unavailable; use set resident mode learning') unless $learned;
        $expected=$learned->{device};
        return (undef,'device does not match authenticated resident') if length($expected) && $device ne $expected;
    } else {
        return (undef,'device does not match authenticated resident') unless $device eq $expected;
    }
    return (undef,'Invalid entry') unless ($p->{entry}//'') =~ /\A[01]\z/;
    my ($time,$canonical)=GP_ParseTime($p->{date});
    return (undef,'Invalid original event date') unless defined $time;
    return (undef,'Invalid location id') unless GP_Id($p->{id});
    my @zones=map {$cfg->{zones}{$_}} @{$cfg->{zone_ids}{lc $p->{id}}//[]};
    return (undef,'Unknown location id; use set resident mode learning and send an isTest=true webhook') unless @zones==1 || $learning;
    my $z=$zones[0];
    return (undef,'Invalid location name') if defined($p->{name}) && length($p->{name})>200;
    return (undef,'Missing or invalid zone geometry') unless GP_HasGeometry({lat=>$p->{latitude},lon=>$p->{longitude},radius=>$p->{radius}});
    my $position={lat=>0+$p->{latitude},lon=>0+$p->{longitude}};
    my $motion=lc($p->{motion}//'unknown');
    my %motion=(automotive=>'automotive',walking=>'walking',running=>'running',cycling=>'cycling',stationary=>'stationary');
    $motion=$motion{$motion}//'unknown';
    my $current;
    if (GP_Number($p->{currentLatitude}) && abs($p->{currentLatitude})<=90
        && GP_Number($p->{currentLongitude}) && abs($p->{currentLongitude})<=180) {
        $current={lat=>0+$p->{currentLatitude},lon=>0+$p->{currentLongitude}};
    }
    return ({kind=>'geo',device=>$device,zone=>$z ? $z->{name}:undef,zone_id=>lc($p->{id}),zone_name=>$p->{name}//'',
        geometry=>{%$position,radius=>0+$p->{radius}},entry=>0+$p->{entry},time=>$time,received=>$now,motion=>$motion,
        key=>join('|',$device,lc($p->{id}),$p->{entry},$canonical),
        zone_position=>$position,current_position=>$current,revision=>GP_ConfigRevision($cfg)},undef);
}

# GP_Learned: Return captured enrollment data while its device binding still matches.
sub GP_Learned {
    my ($c,$r)=@_;
    my $learned=$c->{helper}{gp}{learned}{$r};
    # Expiry limits incoming learning events, not the time to copy manual commands.
    return unless $learned;
    my $configured=lc GP_Attr($r,'deviceId','');
    return unless $learned->{unbound}
        ? !length($configured)
        : $learned->{device} eq $configured;
    return $learned;
}

# GP_LearningDeviceConflict: Detect a device identifier already configured or being learned elsewhere.
sub GP_LearningDeviceConflict {
    my ($c,$r,$device)=@_;
    return 'Invalid device identifier' unless GP_Id($device);
    for my $other (GP_Residents($c)) {
        next if $other eq $r;
        next unless GP_UsesSource(GP_Attr($other,'sourceMode','geofency_phone'),'geo');
        return "Device identifier already assigned to $other" if lc GP_Attr($other,'deviceId','') eq $device;
        my $candidate=GP_Learned($c,$other);
        return "Device identifier already being learned for $other"
            if $candidate && $candidate->{unbound} && $candidate->{device} eq $device;
    }
    return;
}

# GP_CaptureLocation: Capture fresh test geometry in the active learning session without actions.
sub GP_CaptureLocation {
    my ($c,$r,$e,$cfg,$now)=@_;
    my $learned=GP_Learned($c,$r) or return (503,'Learning expired; start again');
    return (503,'Learning expired; start again') unless $c->{helper}{gp}{learning}{$r}
        && GP_Mono()<=$learned->{until};
    return (422,'Learning requires a fresh test event') unless GP_Fresh($cfg,$e,$now) && $e->{time}>=$learned->{start}-1;
    my $conflict=GP_LearningDeviceConflict($c,$r,$e->{device});
    return (422,$conflict) if $conflict;
    my $old=$learned->{zones}{$e->{zone_id}};
    return (422,'Older learning observation ignored') if $old && $e->{time}<$old->{time};
    return (422,'Conflicting learning observation; send a newer test event') if $old && $e->{time}==$old->{time}
        && $GP_JSON->encode($old->{geometry}) ne $GP_JSON->encode($e->{geometry});
    return (429,'At most 32 locations per learning session') unless $old || keys(%{$learned->{zones}})<32;
    # Pin the candidate only AFTER validating the complete fresh observation.
    # HTTP reception never writes the deviceId attribute or calls CommandAttr.
    if ($learned->{unbound} && !length($learned->{device})) {
        $learned->{device}=$e->{device};
        GP_Log($c,3,'learning_device_captured',{resident=>$r,mode=>'learning',reason=>'Device identifier captured; use learnConfirm to confirm'});
    }
    $learned->{zones}{$e->{zone_id}}={id=>$e->{zone_id},name=>$e->{zone_name},geometry=>$e->{geometry},time=>$e->{time},
        number=>$old ? $old->{number}:1+keys(%{$learned->{zones}})};
    return (200,'OK learning captured; no actions');
}

# GP_BeginLearning: Validate enrollment prerequisites and open a bounded learning window.
sub GP_BeginLearning {
    my ($c,$r)=@_;
    return 'Enable the controller with set '.$c->{NAME}.' mode debug or active first' if GP_Mode($c->{NAME}) eq 'disabled';
    return 'Learning requires a Geofency source' unless GP_UsesSource(GP_Attr($r,'sourceMode','geofency_phone'),'geo');
    my $device=lc GP_Attr($r,'deviceId','');
    return 'Invalid configured deviceId; remove or correct it before learning' if length($device) && !GP_Id($device);
    my $user=GP_Attr($r,'webhookUser','');
    return 'Learning requires a unique webhookUser and a stored webhookPassword' unless GP_Id($user)
        && 1==grep {GP_Attr($_,'webhookUser','') eq $user
            && GP_UsesSource(GP_Attr($_,'sourceMode','geofency_phone'),'geo')} GP_Residents($c);
    my ($error,$auth)=GP_Auth($r);
    return 'Learning requires a stored webhookPassword' if $error || ($auth//'') !~ /\A[a-f0-9]{32}:[a-f0-9]{64}\z/;
    my $conflict=length($device) ? GP_LearningDeviceConflict($c,$r,$device) : undef;
    return $conflict if $conflict;
    GP_ResetResident($c,$r);
    my $rt=$c->{helper}{gp};
    $rt->{learned}{$r}={device=>$device,unbound=>length($device)?0:1,confirmed=>0,
        start=>GP_Now(),until=>GP_Mono()+900,zones=>{}};
    $rt->{learning}{$r}=1;
    GP_StoreMode($defs{$r},'learning');
    GP_UpdateModes($c);
    GP_Log($c,3,'learning_started',{resident=>$r,mode=>'learning',reason=>'15 minute window for isTest=true webhooks; no journeys or actions'});
    return 'Learning for 15 minutes; send Geofency entry/exit tests to the normal webhook URL; use set '.$r.' learnConfirm afterwards';
}

# GP_ExpireLearning: Stop expired learning reception while retaining data for explicit confirmation.
sub GP_ExpireLearning {
    my ($c,$r)=@_;
    return unless GP_Mode($r) eq 'learning';
    my $rt=$c->{helper}{gp}; my $learned=GP_Learned($c,$r);
    return if $learned && $rt->{learning}{$r} && GP_Mono()<=$learned->{until};
    GP_ResetResident($c,$r,'capture');
    $learned->{expired}=1 if $learned;
    GP_UpdateModes($c);
    GP_Log($c,3,'learning_expired',{resident=>$r,mode=>'learning',reason=>'Reception stopped; resident disabled; captured data awaits explicit learnConfirm'});
}

# GP_LearnConfirm: Confirm captured setup data and leave the resident disabled.
sub GP_LearnConfirm {
    my ($c,$r)=@_;
    return 'Controller unavailable' unless $c && $c->{helper}{gp};
    my $rt=$c->{helper}{gp}; my $learned=GP_Learned($c,$r);
    return 'No captured learning data; use set '.$r.' mode learning first' unless $learned;
    return 'Learning already confirmed; resident mode unchanged' if $learned->{confirmed};
    return 'Learning confirmation requires learning or disabled mode' unless GP_Mode($r) =~ /\A(?:learning|disabled)\z/;
    return 'No device or location captured; send a fresh Geofency test before confirming'
        unless length($learned->{device}) && keys %{$learned->{zones}};
    my $conflict=GP_LearningDeviceConflict($c,$r,$learned->{device});
    return $conflict if $conflict;
    # Close reception before committing an ordinary FHEM attribute. Any callbacks
    # may reconfigure the resident: never resurrect their superseded setup state.
    GP_ResetResident($c,$r,'capture');
    GP_UpdateModes($c);
    if ($learned->{unbound}) {
        my $resident=$defs{$r}; my $generation=$rt->{resident_generation}{$r};
        my $error=CommandAttr($c->{CL},"$r deviceId $learned->{device}");
        return "Cannot confirm device identifier: $error" if $error;
        return 'Device confirmation interrupted by a configuration change; check deviceId and restart learning'
            unless ($defs{$r}//0)==$resident && GP_TimerCurrent($c,$rt)
                && GP_Attr($r,'deviceId','') eq $learned->{device} && GP_Mode($r) eq 'disabled'
                && $rt->{resident_generation}{$r}==$generation+1;
        delete $learned->{unbound};
    }
    $learned->{confirmed}=1;
    $rt->{learned}{$r}=$learned;
    # A synchronous attribute callback may have queried debug geometry before
    # confirmation. It must not hide the newly confirmed setup metadata.
    delete $rt->{geometry}{debug}{$r};
    GP_InvalidateConfig($c,$r,1);
    GP_Log($c,3,'learning_confirmed',{resident=>$r,mode=>'learning',reason=>'Device identifier and captured locations confirmed; resident remains disabled'});
    return 'Learning confirmed; deviceId '.$learned->{device}.' configured; resident disabled; create locations and applyGeometry before testing';
}

# GP_SetMode: Validate a requested operating mode and reset contexts affected by the transition.
sub GP_SetMode {
    my ($d,$mode)=@_;
    my $kind=$d->{SUBTYPE}//''; my $name=$d->{NAME}; my $c=GP_Controller($d);
    return 'mode is available on controllers and residents only' unless $kind eq 'controller' || $kind eq 'resident';
    return 'Controller unavailable' unless $c && $c->{helper}{gp};
    return 'Choose active, debug, disabled'.($kind eq 'resident'?' or learning':'')
        unless defined($mode) && ($mode =~ /\A(?:active|debug|disabled)\z/ || ($kind eq 'resident' && $mode eq 'learning'));
    GP_ExpireLearning($c,$name) if $kind eq 'resident';
    if (GP_Mode($name) eq $mode) {
        # An expired window leaves a reviewable candidate while disabled. An
        # explicit disabled command is also the operator's cancellation path.
        if ($kind eq 'resident' && $mode eq 'disabled' && $c->{helper}{gp}{learned}{$name} && !$c->{helper}{gp}{learned}{$name}{confirmed}) {
            GP_ResetResident($c,$name); GP_UpdateModes($c);
        }
        return;
    }
    return GP_BeginLearning($c,$name) if $mode eq 'learning';
    if ($mode eq 'active') {
        # Validate the proposed effective configuration without committing state.
        local $d->{READINGS}{mode}{VAL}=$mode;
        my @errors=GP_Validate($c,$kind eq 'resident' ? $name:undef,1);
        return 'Cannot activate: '.join('; ',@errors) if @errors;
    }
    if ($kind eq 'controller') {
        # Mode changes never rebind the listening socket. Hardware feedback for
        # already dispatched requests remains observed across every transition.
        GP_ResetResident($c,$_,$mode eq 'disabled'?'':'learning') for GP_Residents($c);
    } else { GP_ResetResident($c,$name); }
    GP_StoreMode($d,$mode);
    $d->{STATE}=$mode if $kind eq 'controller';
    GP_UpdateModes($c);
    GP_Log($c,3,'mode_changed',{($kind eq 'resident'?(resident=>$name):()),mode=>$mode,
        reason=>'Mode changed; previous journeys and opening permissions revoked'});
    return;
}

# GP_HTTP: Handle a dedicated webhook request and record its response diagnostics.
# Called only by the dedicated listener; there is no FHEMWEB command dispatcher.
sub GP_HTTP {
    my ($c,$method,$path,$headers,$body)=@_;
    my $diag={route=>'unknown'};
    my ($status,$text)=GP_HandleHTTP($c,$method,$path,$headers,$body,$diag);
    my $level=$status>=400 && $status!=404 && $status!=405 ? 2:4;
    @{$diag}{qw(status reason)}=($status,$text);
    GP_Log($c,$level,'http',$diag);
    return ($status,$text);
}

# GP_HandleHTTP: Authenticate, validate, and route a webhook into learning or the event queue.
sub GP_HandleHTTP {
    my ($c,$method,$path,$headers,$body,$diag)=@_;
    return (404,'Unknown webhook') unless $c;
    my $base='/fhem/'.GP_Attr($c->{NAME},'webhookPath','geopresence');
    return (404,'Unknown webhook') unless $path eq $base;
    $diag->{route}='webhook';
    return (405,'POST required') unless $method eq 'POST';
    return (415,'application/x-www-form-urlencoded required') unless ($headers->{'content-type'}//'') =~ m{\Aapplication/x-www-form-urlencoded(?:\s*;|\z)}i;
    return (413,'Request too large') if length($body)>16384;
    my $rt=$c->{helper}{gp};
    return (503,'Initializing') unless $rt && $rt->{ready};
    my $auth=$headers->{authorization}//'';
    return (401,'Authentication required') unless $auth =~ /\ABasic ([A-Za-z0-9+\/=]+)\z/;
    my ($user,$password)=split /:/,decode_base64($1),2;
    return (401,'Authentication required') unless defined($password) && length($password)<=256;
    my $res=GP_Catalog($c)->{users}{$user};
    return (401,'Authentication required') unless $res && @$res==1;
    my $r=$res->[0];
    my ($err,$stored)=GP_Auth($r);
    return (401,'Authentication required') if $err || !defined($stored) || $stored !~ /\A([a-f0-9]{32}):([a-f0-9]{64})\z/;
    my ($salt,$expected)=($1,$2);
    my $actual=sha256_hex($salt.':'.$password);
    my $diff=0; $diff|=ord(substr($actual,$_,1))^ord(substr($expected,$_,1)) for 0..63;
    return (401,'Authentication required') if $diff;
    $diag->{resident}=$r;
    # Failed logins cannot consume another resident's processing capacity.
    # One bounded window covers production, debug and learning for this person.
    my ($now,$mono)=(GP_Now(),GP_Mono());
    my $rate=$rt->{http_rate}{$r};
    $rate=$rt->{http_rate}{$r}={start=>$mono,count=>0} if !$rate || $mono-$rate->{start}>=60;
    return (429,'Rate limit') if $rate->{count}>=120;
    $rate->{count}++;
    GP_ExpireLearning($c,$r);
    my $mode=GP_EffectiveMode($c,$r,0);
    $diag->{mode}=$mode;
    return (503,'Resident disabled') if $mode eq 'disabled';
    my ($p,$parse_error,$form_info)=GP_DecodeForm($body);
    return (400,$parse_error) if $parse_error;
    $diag->{ignored_multiline}=$form_info->{ignored_multiline} if length($form_info->{ignored_multiline}//'');
    return (400,'FHEM control fields are not webhook data') if grep {
        /\A(?:cmd(?:\..*)?|xhr|jsonp|fwcsrf|inform|asyncoutput)\z/i
    } keys %$p;
    # A test flag can only REMOVE productive authority. Authenticate first,
    # reject malformed markers, then choose the isolated pool before any state,
    # geometry or permission is read or changed for this observation.
    return (400,'Use the case-sensitive field name isTest') if grep {lc($_) eq 'istest' && $_ ne 'isTest'} keys %$p;
    return (400,'isTest must be true, false, 1 or 0') if exists($p->{isTest}) && $p->{isTest} !~ /\A(?:true|false|1|0)\z/;
    my $test=($p->{isTest}//'false') =~ /\A(?:true|1)\z/ ? 1:0;
    $mode=GP_EffectiveMode($c,$r,$test);
    @{$diag}{qw(mode isTest)}=($mode,$test);
    my $cfg=GP_Config($c,$r,$mode eq 'debug');
    return (403,'Resident has no Geofency source') unless GP_UsesSource($cfg->{sourceMode},'geo');
    my $learning=$mode eq 'learning' && $rt->{learning}{$r};
    # During explicit enrollment, spontaneous real observations are acknowledged
    # but do not enroll a phone/zone or enter either trip state. Geofency need not
    # retry these intentionally ignored observations after setup has finished.
    return (200,'OK ignored during learning; isTest=true required; no actions') if $learning && !$test;
    my ($e,$invalid)=GP_Normalize($c,$r,$cfg,$p,$now,$learning);
    $e->{received_mono}=$mono if $e;
    @{$diag}{qw(zone entry observed)}=($e->{zone},$e->{entry},$e->{time}) if $e;
    if ($learning) {
        return (422,$invalid) if $invalid;
        return GP_CaptureLocation($c,$r,$e,$cfg,$now);
    }
    my @errors=GP_Validate($c,$r,$mode eq 'active',$cfg);
    return (503,'Configuration invalid; see get validate') if @errors;
    my $s=GP_State($c,$r,$mode eq 'debug');
    if ($invalid) {
        GP_Trace($s,$now,$invalid);
        return (422,$invalid);
    }
    return (503,'Queue full') if @{$rt->{queue}}>=128;
    push @{$rt->{queue}}, {resident=>$r,debug=>$mode eq 'debug'?1:0,event=>$e,
        due=>$mono+$cfg->{reorder_window},epoch=>$rt->{epoch}};
    return (200,$mode eq 'debug' ? 'OK debug accepted; no actions' : 'OK accepted in current FHEM session');
}

# GP_ActorFeedbackSources: List the device and Reading pairs used to confirm an opening request.
sub GP_ActorFeedbackSources {
    my ($intent)=@_;
    my $p=$intent->{params};
    return $intent->{kind} eq 'door_open' ? ([$p->{feedbackDevice},'pulse_state'])
        : ([$p->{stateDevice},'state'],[$p->{upperContact},'state'],[$p->{lowerContact},'state']);
}

# GP_ReadingFingerprint: Combine a Reading's timestamp and value to detect actual updates.
sub GP_ReadingFingerprint {
    my ($device,$reading)=@_;
    return (GP_Reading($device,$reading)->{TIME}//'')."\0".GP_Read($device,$reading,'');
}

# GP_ActorReadingFresh: Check for feedback observed after an actor reservation was created.
sub GP_ActorReadingFresh {
    my ($actor,$device,$reading)=@_;
    my $time=GP_ReadingTime($device,$reading);
    # TIME represents a whole second, not the beginning of the actual update.
    # Accept the dispatch second only with evidence of an update after reserving
    # this actor. Rounding alone could reuse a preceding pulse's confirmation.
    return 0 unless defined($time) && $time>=int($actor->{start});
    my $watch=$actor->{feedback}{$device}{$reading} or return 0;
    my $current=GP_ReadingFingerprint($device,$reading);
    return $current ne $watch->{before} || $current eq ($watch->{observed}//'');
}

# GP_UpdateNotifyDevices: Subscribe the controller to global, ROOMMATE, and active actor events.
sub GP_UpdateNotifyDevices {
    my ($c)=@_;
    my %devices=(global=>1);
    $devices{$defs{$_}{ROOMMATE}}=1 for GP_Residents($c);
    for my $actor (values %{$c->{helper}{gp}{actors}}) {
        $devices{$_}=1 for keys %{$actor->{feedback}//{}};
    }
    my $notify=join(',',sort keys %devices);
    setNotifyDev($c,$notify) if ($c->{NOTIFYDEV}//'') ne $notify;
}

# GP_ActorPositionUsable: Validate a position source against its health, timestamp, and signal mode.
sub GP_ActorPositionUsable {
    my ($device,$reading,$start,$mode)=@_;
    my $d=$defs{$device} or return 0;
    my $time=GP_ReadingTime($device,$reading);
    return 0 unless defined($time) && $time<=GP_Now();
    return 0 if GP_Attr($device,'disable',0) || (($d->{helper}//{})->{DISABLED})
        || ($d->{STATE}//'') =~ /\A(?:disconnected|disabled|error|timeout|unreachable|dead)(?:\b|:)/i
        || GP_Read($device,'Activity','') eq 'dead';
    if (defined(my $io=$d->{IODev})) {
        $io=$defs{$io} unless ref($io);
        return 0 unless ref($io) eq 'HASH' && defined($io->{NAME})
            && ($defs{$io->{NAME}}//0)==$io;
        return 0 if GP_Attr($io->{NAME},'disable',0) || (($io->{helper}//{})->{DISABLED})
            || ($io->{STATE}//'') =~ /\A(?:disconnected|disabled|error|timeout|unreachable|dead)(?:\b|:)/i;
    }
    return $mode eq 'measurement' ? $time>$start : 1;
}

# GP_ActorView: Classify door or garage position from validated contact and state Readings.
sub GP_ActorView {
    my ($intent,$start,$actor)=@_;
    my $p=$intent->{params};
    my @needed=$intent->{kind} eq 'door_open' ? ([$p->{contact},'state'])
        : ([$p->{stateDevice},'state'],[$p->{upperContact},'state'],[$p->{lowerContact},'state']);
    for my $ref (@needed) {
        if ($actor) {
            return 'unknown' unless GP_ActorReadingFresh($actor,@$ref);
        } else {
            return 'unknown' unless GP_ActorPositionUsable(@$ref,$start,$p->{positionSignalMode}//'state');
        }
    }
    if ($intent->{kind} eq 'door_open') {
        my $contact=GP_Read($p->{contact},'state','unknown');
        return 'open' if $contact eq 'open';
        return 'unknown' unless $contact eq 'closed';
        return 'opening' if GP_Read($p->{feedbackDevice},'pulse_state','unknown') eq 'pending';
        return 'closed';
    }
    my $up=GP_Read($p->{upperContact},'state','unknown');
    my $down=GP_Read($p->{lowerContact},'state','unknown');
    my $state=GP_Read($p->{stateDevice},'state','unknown');
    return 'closed' if $up eq 'open' && $down eq 'closed' && $state eq 'off';
    return 'open' if $up eq 'closed' && $down eq 'open' && $state eq 'on';
    return 'opening' if $up eq 'open' && $down eq 'open' && $state eq 'movup';
    return 'closing' if $up eq 'open' && $down eq 'open' && $state eq 'movdown';
    return 'unknown';
}

# GP_ActorResult: Return a retained or freshly confirmed completion result for an actor request.
sub GP_ActorResult {
    my ($actor)=@_;
    return $actor->{completion} if defined($actor->{completion});
    my $intent=$actor->{intent};
    if ($intent->{kind} eq 'door_open') {
        my $device=$intent->{params}{feedbackDevice};
        my $value=GP_Read($device,'pulse_state','');
        return $value if GP_ActorReadingFresh($actor,$device,'pulse_state')
            && $value =~ /\A(?:confirmed|failed|cancelled)\z/;
    } else {
        return 'confirmed' if GP_ActorView($intent,$actor->{start},$actor) eq 'open';
    }
    return;
}

# GP_CanOutput: Check current session, mode, and resident bindings before publishing or dispatching.
sub GP_CanOutput {
    my ($c,$r,$s,$cfg,$debug)=@_;
    my $rt=$c->{helper}{gp};
    my $pool=$debug ? 'debug':'prod';
    # Configuration edits reset their affected contexts or revoke their output
    # versions. An unrelated shared-cache rebuild needs neither a new catalogue
    # nor cancellation of this still-valid immutable resident snapshot.
    return 0 unless $rt && GP_TimerCurrent($c,$rt) && $rt->{ready}
        && GP_EffectiveMode($c,$r,$debug) eq ($debug ? 'debug':'active')
        && ($rt->{$pool}{$r}//0)==$s && !$s->{conflict}
        && ($cfg->{resident}//'') eq $r && GP_Field($cfg->{roommate},'TYPE','') eq 'ROOMMATE'
        && !$c->{helper}{gp_http_error} && (!$cfg->{notify_required} || defined &pushMsg);
    return 1;
}

# GP_OutputReady: Return current clocks only when an intent still passes all output guards.
sub GP_OutputReady {
    my ($c,$r,$cfg,$s,$debug,$intent)=@_;
    my $current=GP_CanOutput($c,$r,$s,$cfg,$debug);
    my $offset=$debug ? ($s->{debug_offset}//0):0;
    my ($now,$mono)=(GP_Now()+$offset,GP_Mono()+$offset);
    my $reason;
    if (!$current) {
        $reason='output context no longer current';
    } else {
        # Caller-supplied timer times never authorize I/O. Static validation
        # belongs to planning; only live permissions are checked here.
        GP_CheckClock($s,$cfg,$now,$mono);
        if (($intent->{generation}//'') ne $s->{generation}
            || !defined($intent->{output_revision}) || $intent->{output_revision}!=$s->{output_revision}) {
            $reason='output permission revoked';
        } elsif ($intent->{after_exit}) {
            my $trip=$s->{trip}//$s->{last_trip}//{};
            my $proof=($trip->{exits}//{})->{$intent->{after_exit}};
            $reason='prior exit revoked before dispatch' unless ($trip->{id}//'') eq ($intent->{trip}//'')
                && defined($proof) && $proof==$intent->{exit_time};
        }
        if (!$reason && (($intent->{trigger}//'') eq 'arrival' || GP_IsOpening($intent->{kind}))) {
            my $trip=$s->{last_trip}//{};
            $reason='arrival permission revoked before dispatch' unless $s->{phase} eq 'home'
                && $trip->{armed} && ($trip->{id}//'') eq ($intent->{trip}//'')
                && GP_UsesSource($cfg->{sourceMode},'geo') && $cfg->{geometry_ready};
            $reason='resident has no permission for this actor' if !$reason
                && (($intent->{kind} eq 'door_open' && !$cfg->{allowDoor})
                    || ($intent->{kind} eq 'garage_open' && !$cfg->{allowGarage}));
        }
        $reason='intent expired' if !$reason && (!GP_ActionFresh($cfg,$intent->{e},$now)
            || !defined($intent->{expires_mono}) || $mono>$intent->{expires_mono});
    }
    return ($now,$mono) unless $reason;
    GP_Trace($s,$now,$reason,{rule=>$intent->{rule},kind=>$intent->{kind},decision=>'suppressed'});
    return;
}

# GP_Dispatch: Dispatch eligible intents or record simulated plans through the fixed adapters.
sub GP_Dispatch {
    my ($c,$r,$cfg,$s,$debug)=@_;
    # Consuming the trip is checkpointed BEFORE any synchronous device/logging
    # callback can save state or reload the module during an opening request.
    GP_Checkpoint($c,$r,$cfg,$s) unless $debug;
    my $intents=$s->{intents}; $s->{intents}=[];
    my $revision=$s->{output_revision};
    for my $intent (@$intents) {
        # A callback can invalidate the whole remainder. Do not walk and log
        # every obsolete candidate after a mode/configuration reset or revoke.
        last if $s->{output_revision}!=$revision || !GP_CanOutput($c,$r,$s,$cfg,$debug);
        my ($now,$mono);
        if ($debug) {
            ($now,$mono)=GP_OutputReady($c,$r,$cfg,$s,1,$intent);
            next unless defined $now;
            GP_Trace($s,$now,'would execute; debug suppressed', {rule=>$intent->{rule},kind=>$intent->{kind},target=>$intent->{params}{target}//'pushMsg'});
            next;
        }
        my $p=$intent->{params};
        if ($intent->{kind} eq 'notify') {
            my $message=$p->{message}//'';
            $message =~ s/%resident%/$cfg->{label}/g;
            unless (GP_SafeText($message)) { GP_Trace($s,GP_Now(),'unsafe notification text rejected'); next; }
            ($now,$mono)=GP_OutputReady($c,$r,$cfg,$s,0,$intent);
            next unless defined $now;
            my $ok=eval {GP_Profile($c,'notification','pushMsg',sub {pushMsg($p->{channel}//0,$p->{priority}//0,$message)});1};
            GP_RecordAction($c,$r,$s,$now,$ok?'notification dispatched':'notification failed',
                {rule=>$intent->{rule},channel=>$p->{channel}//0,message=>$message});
            next;
        }
        if ($intent->{kind} eq 'switch_on') {
            # A fixed, idempotent on command; never an opening reservation and
            # never arbitrary FHEM command text. Configuration validates target
            # conflicts with door/garage actions before accepting an event.
            next unless GP_Name($p->{target}) && exists($defs{$p->{target}}) && ($p->{command}//'') eq 'on';
            ($now,$mono)=GP_OutputReady($c,$r,$cfg,$s,0,$intent);
            next unless defined $now;
            my $error=eval {GP_Profile($c,'actor_command',$p->{target},sub {CommandSet(undef,$p->{target}.' on')})};
            $error=$@ if $@;
            GP_RecordAction($c,$r,$s,$now,$error ? 'switch command failed':'switch command dispatched',
                {rule=>$intent->{rule},kind=>'switch_on',target=>$p->{target}});
            next;
        }
        next unless GP_IsOpening($intent->{kind});
        my $target=$p->{target};
        my $command=$intent->{kind} eq 'door_open' ? 'lock unlocked':'on';
        next unless ($p->{command}//'') eq $command;
        my $rt=$c->{helper}{gp};
        ($now,$mono)=GP_OutputReady($c,$r,$cfg,$s,0,$intent);
        next unless defined $now;
        # A preceding resident's command may already have completed synchronously
        # in this timer pass. Only a still-pending request can be shared.
        if ($rt->{actors}{$target}) {
            GP_ActorFeedback($c,$now,$mono);
            ($now,$mono)=GP_OutputReady($c,$r,$cfg,$s,0,$intent);
            next unless defined $now;
        }
        if ($rt->{actors}{$target}) {
            $rt->{actors}{$target}{waiters}{$r}=1;
            GP_Trace($s,$now,'shared actor already pending',{target=>$target});
            $s->{$intent->{kind} eq 'door_open'?'door_result':'garage_result'}='shared';
            next;
        }
        my $view=GP_ActorView($intent,$rt->{start});
        my $result=$intent->{kind} eq 'door_open'?'door_result':'garage_result';
        if ($view eq 'open' || $view eq 'opening') {
            $s->{$result}='already_satisfied'; GP_Trace($s,$now,'actor already open or opening',{target=>$target}); next;
        }
        unless ($view eq 'closed') {
            $s->{$result}='suppressed'; GP_Trace($s,$now,'actor position does not permit opening',{target=>$target,state=>$view}); next;
        }
        # Reserve before CommandSet: DOIF/readings callbacks can run synchronously.
        my $actor=$rt->{actors}{$target}={intent=>$intent,start=>$now,mono=>$mono,waiters=>{$r=>1},timeout=>$cfg->{actor_timeout}};
        for my $ref (GP_ActorFeedbackSources($intent)) {
            $actor->{feedback}{$ref->[0]}{$ref->[1]}={before=>GP_ReadingFingerprint(@$ref)};
        }
        # Subscribe before CommandSet as the complete pulse may be reported
        # synchronously, with the same value and TIME as the previous pulse.
        GP_UpdateNotifyDevices($c);
        ($now,$mono)=GP_OutputReady($c,$r,$cfg,$s,0,$intent);
        unless (defined $now) {
            # This reservation has not issued a command. Remove only our own
            # slot, including if a reset retained the shared actors hash.
            delete $rt->{actors}{$target} if ($rt->{actors}{$target}//0)==$actor;
            GP_UpdateNotifyDevices($c) if $c->{helper}{gp} && GP_TimerCurrent($c,$c->{helper}{gp});
            next;
        }
        @{$actor}{qw(start mono)}=($now,$mono);
        $s->{$result}='dispatch_started';
        my $error=eval {GP_Profile($c,'actor_command',$target,sub {CommandSet(undef,$target.' '.$command)})};
        $error=$@ if $@;
        $s->{$result}=$error ? 'failed':'pending';
        GP_RecordAction($c,$r,$s,$now,$error?'actor command failed':'actor command dispatched',
            {target=>$target,rule=>$intent->{rule},kind=>$intent->{kind}});
    }
}

# GP_Publish: Persist travel evidence, synchronize ROOMMATE, and publish changed resident Readings.
sub GP_Publish {
    my ($c,$r,$cfg,$s)=@_;
    # A revoked checkpoint must reach saved Readings even when status output is blocked.
    GP_Checkpoint($c,$r,$cfg,$s);
    return unless GP_CanOutput($c,$r,$s,$cfg,0);
    if (my $status=delete $s->{desired_status}) {
        my $rr=$defs{$r}{ROOMMATE};
        my $retry;
        my $current=GP_Read($rr,'state','unknown');
        my $set=($status eq 'home' && $current !~ /\A(?:home|gotosleep|asleep|awoken)\z/)
            || ($status eq 'absent' && $current !~ /\A(?:absent|gone)\z/);
        my $error;
        if ($set) {
            my $request={device=>$defs{$rr},status=>$status};
            local $c->{helper}{gp}{status_request}=$request;
            # FHEM exposes the command client as CL during synchronous events.
            # Restore it even when an adapter throws before CommandSet cleans up.
            local $request->{device}{CL};
            # Observe Home at the Reading writer while this adapter runs. Other
            # receivers may delete caches or rewrite events before Notify sees them.
            my $write_reading=\&setReadingsVal;
            no warnings 'prototype';
            local *setReadingsVal=sub {
                if (($_[1]//'') eq 'state' && ($_[2]//'') eq 'home'
                    && ($_[0]{TYPE}//'') eq 'ROOMMATE'
                    && ($c->{helper}{gp}{status_request}//0)==$request) {
                    my $device=$_[0];
                    if ($device==$request->{device} && $request->{status} eq 'home'
                        && ($device->{CL}//0)==$request && !$request->{home_written}) {
                        $request->{home_written}=1;
                    } else {
                        GP_ManualHome($c,$device);
                        $request->{manual_home}{$device}=1;
                    }
                }
                # Tail delegation preserves the writer's context, result and exception.
                goto &$write_reading;
            };
            $error=eval {GP_Profile($c,'roommate_command',$rr,sub {CommandSet($request,"$rr state $status")})};
            $error=$@ if $@;
        }
        if ($error) {
            $error=GP_LogText($error);
            if (($s->{roommate_error}//'') ne $error) {
                $s->{roommate_error}=$error;
                GP_Log($c,2,'roommate_status_failed',{resident=>$r,mode=>'active',target=>$rr,reason=>$error});
            }
            $retry=$status;
        } elsif (delete $s->{roommate_error}) {
            GP_Log($c,3,'roommate_status_ready',{resident=>$r,mode=>'active',target=>$rr,reason=>'Status update accepted'});
        }
        return unless GP_CanOutput($c,$r,$s,$cfg,0);
        # Recheck after command and log callbacks; keep any newer status request.
        $s->{desired_status}//=$retry if defined $retry;
    }
    my $t=$s->{trip}//{};
    my $arrival=$s->{arrival}//{};
    my %readings=(gp_phase=>$s->{phase},gp_location=>$s->{location}//'unknown',gp_trip_id=>$t->{id}//'',
        gp_trip_scope=>$t->{scope}//'unknown',gp_arrival_armed=>$t->{armed}//0,gp_away_reason=>$t->{away_reason}//'',
        gp_source_mode=>$cfg->{sourceMode},
        gp_roommate_error=>$s->{roommate_error}//'',
        gp_resume_status=>($s->{resume}//{})->{status}//'none',
        gp_resume_reason=>($s->{resume}//{})->{reason}//'No restart recovery in this session',
        gp_phone_state=>$s->{phone}{state},gp_phone_health=>$s->{phone}{health},gp_phone_signal_mode=>$cfg->{phoneSignalMode},
        gp_geometry_ready=>$cfg->{geometry_ready},gp_geometry_reason=>join('; ',@{$cfg->{geometry_errors}}),
        gp_last_observed=>$s->{last_observed}//'',gp_last_received=>$s->{last_received}//'',
        gp_last_delay=>defined($s->{last_observed}) ? sprintf('%.3f',$s->{last_received}-$s->{last_observed}):'',
        gp_motion=>$s->{motion}//'unknown',gp_motion_time=>$s->{motion_time}//'',
        gp_arrival_pending=>$s->{arrival}?1:0,gp_arrival_motion=>$arrival->{motion}//'',
        gp_arrival_deadline=>$arrival->{deadline}//'',gp_arrival_wait=>$arrival->{wait}//'',
        gp_last_decision=>$s->{last_decision},gp_last_reason=>$s->{last_reason},
        gp_door_result=>$s->{door_result}//'not_requested',gp_garage_result=>$s->{garage_result}//'not_requested',
        gp_evidence_state=>($s->{position_time}//0)>$s->{start} ? 'current_session':'restored');
    my $d=$defs{$r};
    my @changed=grep {GP_Read($r,$_,'__missing__') ne $readings{$_}} sort keys %readings;
    return unless @changed;
    readingsBeginUpdate($d);
    readingsBulkUpdate($d,$_,$readings{$_}) for @changed;
    GP_Profile($c,'resident_reading_callbacks',$r,sub {readingsEndUpdate($d,1)});
}

# GP_ActorFeedback: Complete or time out shared actor reservations and update waiting residents.
sub GP_ActorFeedback {
    my ($c,$now,$mono)=@_;
    my $rt=$c->{helper}{gp};
    for my $target (keys %{$rt->{actors}}) {
        my $a=$rt->{actors}{$target}; my $i=$a->{intent};
        my $result=GP_ActorResult($a);
        $result='uncertain' if !$result && $mono-$a->{mono}>$a->{timeout};
        next unless $result;
        # Finish the reservation before calling the logger: Log3 subscribers
        # may reenter this function or create a new request for the same target.
        delete $rt->{actors}{$target};
        for my $r (keys %{$a->{waiters}}) {
            my $s=$rt->{prod}{$r};
            $s->{$i->{kind} eq 'door_open'?'door_result':'garage_result'}=$result if $s;
            GP_RecordAction($c,$r,$s,$now,'actor feedback',{target=>$target,result=>$result,kind=>$i->{kind}});
        }
    }
    GP_UpdateNotifyDevices($c);
}

# GeoPresence_Timer: Run a guarded controller tick, reschedule it, and record its timing.
sub GeoPresence_Timer {
    my ($c)=@_;
    return unless $defs{$c->{NAME}} && $defs{$c->{NAME}}==$c && $c->{helper}{gp};
    return if $c->{helper}{gp_timer_running};
    local $c->{helper}{gp_timer_running}=1;
    my ($now,$mono,$cpu)=(GP_Now(),GP_Mono(),GP_CPU());
    my $due=delete $c->{helper}{gp_timer_due};
    my $lag=defined($due) && $mono>$due ? ($mono-$due)*1000 : 0;
    my $rt=$c->{helper}{gp};
    local $c->{helper}{gp_work}={device_scans=>0,config_builds=>0};
    GP_Profile($c,'timer_registry','remove',sub {RemoveInternalTimer($c,'GeoPresence_Timer')});
    GP_Profile($c,'processing',$c->{NAME},sub {GP_TimerStep($c,$rt,$now,$mono)}) if $init_done;
    my $duration=GP_Mono()-$mono;
    my $stats=$c->{helper}{gp_timer_stats}//={runs=>0,total_ms=>0,max_ms=>0,slow_runs=>0};
    if ($duration>=0.5) {
        if (!defined($stats->{warned_at}) || GP_Mono()-$stats->{warned_at}>=60 || GP_Mono()<$stats->{warned_at}) {
            $stats->{warned_at}=GP_Mono();
            my $sample=GP_TimerSample($c,$now,$mono,$cpu,$lag);
            GP_Log($c,2,'timer_slow',{reason=>'Slow timer work; phase times exclude nested measured calls; this log write is included in timerStats afterwards',
                map {$_=>$sample->{$_}} qw(started_at elapsed_ms cpu_ms start_lag_ms slowest_phase slowest_target slowest_self_ms)});
        }
    }
    # Reading/command callbacks can replace the session and install its timer.
    # Never add another timer to that session or rearm an undefined controller.
    # A slow callback must not schedule its successor in the past.
    GP_Profile($c,'timer_registry','schedule',sub {GP_ScheduleTimer($c,1)}) if GP_TimerCurrent($c,$rt);
    # Include diagnostic output and scheduler calls, even if a synchronous
    # callback replaced the session. No file output from this final accounting.
    my $sample=GP_TimerSample($c,$now,$mono,$cpu,$lag);
    $stats->{runs}++;
    $stats->{last_started_at}=$now;
    $stats->{last_lag_ms}=$lag;
    $stats->{max_lag_ms}=$lag if $lag>($stats->{max_lag_ms}//0);
    $stats->{late_runs}++ if $lag>=500;
    $stats->{last_ms}=$sample->{elapsed_ms};
    $stats->{last_cpu_ms}=$sample->{cpu_ms};
    $stats->{total_ms}+=$stats->{last_ms};
    $stats->{max_ms}=$stats->{last_ms} if $stats->{last_ms}>$stats->{max_ms};
    $stats->{last_device_scans}=$c->{helper}{gp_work}{device_scans};
    $stats->{last_config_builds}=$c->{helper}{gp_work}{config_builds};
    $stats->{profile_started_at}//=$now;
    $stats->{last_run}=$sample;
    $stats->{worst_run}=$sample if !$stats->{worst_run} || $sample->{elapsed_ms}>$stats->{worst_run}{elapsed_ms};
    $stats->{worst_late_run}=$sample if !$stats->{worst_late_run} || $lag>$stats->{worst_late_run}{start_lag_ms};
    if ($sample->{elapsed_ms}>=500) {
        $stats->{slow_runs}++;
        push @{$stats->{recent_slow}},$sample;
        shift @{$stats->{recent_slow}} while @{$stats->{recent_slow}}>12;
    }
    if ($lag>=500) {
        push @{$stats->{recent_late}},$sample;
        shift @{$stats->{recent_late}} while @{$stats->{recent_late}}>12;
    }
}

# GP_TimerSample: Summarize elapsed time, CPU use, and exclusive work by timer phase.
sub GP_TimerSample {
    my ($c,$now,$mono,$cpu,$lag)=@_;
    my $work=$c->{helper}{gp_work};
    my $elapsed=(GP_Mono()-$mono)*1000; $elapsed=0 if $elapsed<0;
    my $cpu_ms=(GP_CPU()-$cpu)*1000; $cpu_ms=0 if $cpu_ms<0;
    my @phases=sort {$b->{self_ms}<=>$a->{self_ms} || $a->{phase} cmp $b->{phase} || $a->{target} cmp $b->{target}}
        map {{%$_}} values %{$work->{phases}//{}};
    my $top=$phases[0]//{};
    return {started_at=>$now,elapsed_ms=>$elapsed,cpu_ms=>$cpu_ms,start_lag_ms=>$lag,
        device_scans=>$work->{device_scans},config_builds=>$work->{config_builds},phases=>\@phases,
        slowest_phase=>$top->{phase}//'unmeasured',slowest_target=>$top->{target}//'',slowest_self_ms=>$top->{self_ms}//0};
}

# GP_TimerSampleView: Return a rounded presentation copy of a timer sample.
sub GP_TimerSampleView {
    my ($sample)=@_;
    return unless $sample;
    my %view=%$sample;
    $view{$_}=0+sprintf('%.3f',$sample->{$_}) for qw(started_at elapsed_ms cpu_ms start_lag_ms slowest_self_ms);
    $view{phases}=[map {{%$_,elapsed_ms=>0+sprintf('%.3f',$_->{elapsed_ms}),self_ms=>0+sprintf('%.3f',$_->{self_ms})}} @{$sample->{phases}}];
    return \%view;
}

# GP_ScheduleTimer: Schedule the next callback and retain its monotonic due time.
sub GP_ScheduleTimer {
    my ($c,$delay)=@_;
    $c->{helper}{gp_timer_due}=GP_Mono()+$delay;
    InternalTimer(GP_Now()+$delay,'GeoPresence_Timer',$c,0);
}

# GP_TimerCurrent: Check that the controller and runtime session still belong to the live device.
sub GP_TimerCurrent {
    my ($c,$rt)=@_;
    return ($defs{$c->{NAME}}//0)==$c && ($c->{helper}{gp}//0)==$rt;
}

# GP_TimerStep: Process listeners, phone samples, ordered batches, arrivals, and outputs.
sub GP_TimerStep {
    my ($c,$rt,$now,$mono)=@_;
    my $registration=GP_Profile($c,'listener',$c->{NAME},sub {GP_EnsureHTTP($c)});
    $rt->{ready}=$registration ? 0:1;
    GP_Log($c,2,'listener_error',{reason=>$registration}) if $registration && ($rt->{error}//'') ne $registration;
    $rt->{error}=$registration//'';
    $c->{STATE}=$registration ? 'configuration error':GP_Mode($c->{NAME});
    GP_Profile($c,'actor_feedback',$c->{NAME},sub {GP_ActorFeedback($c,$now,$mono)});
    return unless GP_TimerCurrent($c,$rt);
    for my $r (GP_Residents($c)) {
        GP_ExpireLearning($c,$r);
        my $mode=GP_EffectiveMode($c,$r,0);
        next if $mode eq 'disabled' || $mode eq 'learning';
        my $first_debug=$mode eq 'active' ? 0:1;
        my $first_cfg=GP_Profile($c,'configuration',$r,sub {GP_Config($c,$r,$first_debug)});
        my @errors=GP_Profile($c,'validation',$r,sub {GP_Validate($c,$r,$mode eq 'active',$first_cfg)});
        my $previous=join('; ',@{$rt->{errors}{$r}//[]});
        my $current=join('; ',@errors);
        GP_Log($c,@errors ? 2:3,@errors ? 'configuration_invalid':'configuration_ready',
            {resident=>$r,mode=>$mode,reason=>$current||'Configuration valid'}) if $current ne $previous;
        $rt->{errors}{$r}=\@errors;
        next if @errors;
        my @pools=$mode eq 'active' ? (0) : (1);
        push @pools,1 if $mode eq 'active' && exists $rt->{debug}{$r};
        # Share source Readings across due pools; each pool retains its own continuity state.
        my $live_samples;
        for my $debug (@pools) {
            my $target=$r.($debug ? ' (debug)':' (production)');
            my $cfg=$debug==$first_debug ? $first_cfg : GP_Profile($c,'configuration',$target,sub {GP_Config($c,$r,$debug)});
            my $s=GP_State($c,$r,$debug,$cfg);
            my $wall=$now+($s->{debug_offset}//0);
            my $clock=$mono+($s->{debug_offset}//0);
            GP_CheckClock($s,$cfg,$wall,$clock);
            if (GP_UsesSource($cfg->{sourceMode},'phone')
                && (!defined($s->{phone_poll_at}) || $clock-$s->{phone_poll_at}>=$cfg->{phone_poll})) {
                my $samples;
                if ($debug && ($s->{phone_mode}//'live') eq 'simulated') {
                    $samples={map {$_=>{value=>$s->{sim_phone}//'absent',time=>$wall,ttl=>150,healthy=>1}} @{$cfg->{proxies}}};
                } else { $samples=$live_samples//=GP_Profile($c,'phone_readings',$target,sub {GP_PhoneSamples($cfg,$now)}); }
                my $phone=GP_Profile($c,'phone',$target,sub {GP_Phone($s,$cfg,$samples,$wall,$clock)});
                if ($phone) {
                    push @{$s->{queued_phones}},$phone;
                    if (@{$s->{queued_phones}}>32) {
                        $s->{queued_phones}=[]; delete @{$s}{qw(trip arrival)};
                        GP_RevokeOutputs($s);
                        GP_ResetNegative($s,$wall);
                        GP_Trace($s,$wall,'phone queue overflow; permissions revoked');
                    }
                }
                $s->{phone_poll_at}=$clock;
            }
            GP_Profile($c,'state_tick',$target,sub {GP_TickState($s,$cfg,$wall,$clock)});
            # The first received observation fixes the window. When it is due,
            # process ALL already received observations in this context so that
            # newer counterevidence is considered before arrival confirmation.
            my @batch=grep {$_->{resident} eq $r && $_->{debug}==$debug} @{$rt->{queue}};
            my $batch_ready=!@batch || grep {$_->{due}<=$mono} @batch;
            if ($batch_ready) {
                @{$rt->{queue}}=grep {!($_->{resident} eq $r && $_->{debug}==$debug)} @{$rt->{queue}};
                my ($geometry_changed,$geometry_conflict)=(0,0);
                my @events;
                # Dequeued events belong to this batch; arrivals and plans keep
                # their own snapshots. Iterate sorted input, collecting output.
                for my $e (sort {$a->{time}<=>$b->{time}} map {$_->{event}}
                    grep {$_->{epoch}==$rt->{epoch}} @batch) {
                    my $result=GP_Profile($c,'geometry',$target,sub {GP_UpdateGeometry($c,$r,$debug,$s,$e,$cfg,$wall)});
                    if ($result eq 'stale') {
                        GP_Trace($s,$wall,'stale geometry observation ignored',{zone=>$e->{zone}});
                        # Do not restore older geometry. An otherwise current
                        # exit with UNCHANGED geometry can still interrupt the
                        # approach or Home wait. A registered motion supplement
                        # may enrich that arrival without rewinding its position.
                        my $z=$cfg->{zones}{$e->{zone}}//{};
                        push @events,$e if (GP_InterruptsArrival($s,$cfg,$e) || GP_MotionOrigin($s,$cfg,$e))
                            && GP_HasGeometry($e->{geometry}) && GP_HasGeometry($z)
                            && !grep {$e->{geometry}{$_}!=$z->{$_}} qw(lat lon radius);
                        next;
                    }
                    $geometry_changed=1 if $result eq 'changed' || $result eq 'conflict';
                    $geometry_conflict=1 if $result eq 'conflict';
                    push @events,$e;
                }
                GP_MergeBatchMotion(@events);
                $cfg=GP_Config($c,$r,$debug) if $geometry_changed;
                my $conflict=$geometry_conflict || GP_BatchConflict($s,$cfg,\@events,$wall);
                my $phones=delete($s->{queued_phones})//[];
                push @events,@$phones unless $geometry_changed;
                my @pending;
                # Absence becomes a usable fact only after its complete window.
                # An earlier Home return must revoke it before it can arm a trip.
                for my $e (sort {($a->{qualified_at}//$a->{time})<=>($b->{qualified_at}//$b->{time})
                    || ($a->{zone}//'') cmp ($b->{zone}//'')} @events) {
                    last if $conflict;
                    if ($geometry_changed) {
                        GP_GeometrySync($s,$cfg,$e,$wall,$clock) if $e->{time}>=($s->{position_time}//0);
                        next;
                    }
                    GP_Profile($c,'observation',$target,sub {GP_Process($s,$cfg,$e,$wall,$clock)});
                    @pending=grep {!GP_IsOpening($_->{kind})} @pending if $s->{conflict};
                    # No command runs until all accepted observations in this batch agree.
                    if ($e->{kind} eq 'geo' && !$e->{entry} && ($e->{role}//'') =~ /\A(?:home|approach|outer)\z/) {
                        @pending=grep {!GP_IsOpening($_->{kind}) || $_->{e}{time}>$e->{time}} @pending;
                    }
                    push @pending, @{$s->{intents}};
                }
                if ($conflict) {
                    delete $s->{trip}; GP_CancelArrival($s,$wall,'conflicting batch'); $s->{conflict}=1;
                    GP_RevokeOutputs($s);
                    GP_Trace($s,$wall,'conflicting batch; actions quarantined');
                }
                $s->{intents}=\@pending;
                # An expired arrival wait may act only after ALL queued Geo and
                # phone observations have been ordered and processed. Never
                # dispatch while an exit is still held by reorder_window.
                GP_Profile($c,'arrival',$target,sub {GP_ConfirmArrival($s,$cfg,$wall,$clock)});
                GP_Profile($c,'dispatch',$target,sub {GP_Dispatch($c,$r,$cfg,$s,$debug)});
                return unless GP_TimerCurrent($c,$rt);
            }
            GP_Profile($c,'publish_geometry',$target,sub {GP_PublishGeometry($c,$r,$s)}) unless $debug;
            return unless GP_TimerCurrent($c,$rt);
            GP_Profile($c,'publish',$target,sub {GP_Publish($c,$r,$cfg,$s)}) unless $debug;
            return unless GP_TimerCurrent($c,$rt);
            GP_Profile($c,'trace_output',$target,sub {GP_LogTrace($c,$r,$s,$debug)});
        }
    }
}

# GP_ManualHome: Revoke travel and output permissions after an external Home event.
sub GP_ManualHome {
    my ($c,$device)=@_;
    for my $r (GP_Residents($c)) {
        next unless $defs{$r}{ROOMMATE} eq $device->{NAME};
        # ROOMMATE bindings are unique.
        last unless GP_EffectiveMode($c,$r,0) eq 'active';
        my $s=GP_State($c,$r,0);
        delete $s->{trip}; GP_CancelArrival($s,GP_Now(),'manual home');
        delete $s->{last_trip}{exits} if $s->{last_trip};
        $s->{members}={};
        $s->{phase}='home'; $s->{boundary}=GP_Now(); GP_RevokeOutputs($s);
        $s->{position_time}=$s->{boundary}; $s->{desired_status}='home';
        GP_ResetNegative($s,$s->{boundary});
        GP_Trace($s,GP_Now(),'manual home; no opening');
        GP_ClearCheckpoint($r,'Manual Home state completed the trip');
        last;
    }
    return;
}

# GeoPresence_Notify: Maintain configuration, revocations, and feedback from FHEM events.
sub GeoPresence_Notify {
    my ($c,$device)=@_;
    return unless ($c->{SUBTYPE}//'') eq 'controller';
    my $events=deviceEvents($device,1)//[];
    if ($device->{NAME} eq 'global') {
        if (grep {/\A(?:INITIALIZED|REREADCFG)\z/} @$events) {
            # State restoration has finished, including when REREADCFG arrives
            # before init_done becomes true. Preserve saved modes/timestamps;
            # only genuinely absent modes need the disabled default.
            for my $d ($c,map {$defs{$_}} GP_Residents($c)) {
                GP_StoreMode($d,'disabled') unless length GP_Read($d->{NAME},'mode','');
            }
            GP_UpdateAttrLists();
            GP_ResetController($c,'resume');
        } elsif ($init_done) {
            for my $event (@$events) {
                my $catalog=$c->{helper}{gp_config};
                my $inventory=$c->{helper}{gp_devices};
                if ($event =~ /\A(DEFINED|DELETED|RENAMED|MODIFIED) (\S+)(?: (\S+))?/) {
                    my $operation=$1; my @names=grep {defined} ($2,$3);
                    # RenameFn already revoked contexts and refreshed our own
                    # membership. The subsequent global event needs only widgets.
                    if ($operation eq 'RENAMED' && $inventory && $inventory->{members}{$names[1]//''}
                        && !$inventory->{members}{$names[0]} && GP_Field($names[1],'TYPE','') eq 'GeoPresence'
                        && GP_Field($names[1],'CONTROLLER','') eq $c->{NAME}) {
                        GP_UpdateAttrLists();
                        next;
                    }
                    GP_RevokeDependentOutputs($c,@names);
                    my $own=grep {
                        ($inventory && $inventory->{members}{$_}) || (GP_Field($_,'TYPE','') eq 'GeoPresence'
                            && GP_Field($_,'CONTROLLER','') eq $c->{NAME})
                    } @names;
                    if ($own && $operation ne 'MODIFIED') {
                        GP_InvalidateDevices($c);
                    } elsif ($own || ($catalog && grep {$catalog->{dependents}{$_}} @names)) {
                        GP_InvalidateConfig($c);
                    }
                    # Only GeoPresence/PRESENCE membership affects choices.
                    # Keep conservative refreshes for deleted or unknown types.
                    if ($operation ne 'MODIFIED') {
                        my $type=GP_Field($names[$operation eq 'RENAMED' ? 1:0]//'','TYPE','');
                        GP_UpdateAttrLists() if $operation eq 'DELETED' || !length($type)
                            || $type =~ /\A(?:GeoPresence|PRESENCE)\z/;
                    }
                } elsif ($event =~ /\A(ATTR|DELETEATTR) (\S+)(?: (.*))?\z/s) {
                    my ($operation,$name,$key)=($1,$2,$3//'');
                    $key =~ s/\s.*//s if $operation eq 'ATTR';
                    next if $GP_DISPLAY_ATTR{$key} && $key ne 'alias';
                    my $own=($inventory && $inventory->{members}{$name})
                        || (GP_Field($name,'TYPE','') eq 'GeoPresence' && GP_Field($name,'CONTROLLER','') eq $c->{NAME});
                    my $dependent=($c->{helper}{gp_output_dependencies}//{})->{$name};
                    next unless $own || $dependent;
                    my @keys=($key);
                    if ($operation eq 'DELETEATTR' && $key !~ /\A[\w-]+\z/) {
                        # FHEM reports the original pattern after deletion.
                        # Resolve external names from FHEM's device schema;
                        # removed attributes are no longer in the live hash.
                        my @available=$own
                            ? (@{$GP_ATTRS{$defs{$name}{SUBTYPE}//''}//[]},keys %GP_LEGACY_ATTR,keys %GP_DISPLAY_ATTR)
                            : (map {s/:.*//r} (split(/\s+/,getAllAttr($name)),keys %{$attr{$name}//{}}));
                        @keys=GP_MatchingAttrs($key,@available);
                    }
                    my $alias=grep {$_ eq 'alias'} @keys;
                    @keys=grep {!$GP_DISPLAY_ATTR{$_}} @keys;
                    unless (@keys) {
                        # Only ROOMMATE labels are cached in resident snapshots;
                        # display-only changes never revoke pending outputs.
                        GP_InvalidateConfig($c) if $alias && $catalog && $dependent
                            && GP_Field($name,'TYPE','') eq 'ROOMMATE';
                        next;
                    }
                    my $relevant=$own
                        ? scalar(grep {$GP_ALLOWED{$_} || $GP_LEGACY_ATTR{$_}} @keys)
                        : $dependent;
                    next unless $relevant;
                    GP_RevokeDependentOutputs($c,$name);
                    GP_InvalidateConfig($c);
                }
            }
        }
        return;
    }
    # Observe only the feedback readings of already dispatched actors. This is
    # passive even when a mode change leaves an outstanding hardware request.
    for my $actor (values %{$c->{helper}{gp}{actors}//{}}) {
        my $watch=$actor->{feedback}{$device->{NAME}} or next;
        my $updated=0;
        for my $reading (keys %$watch) {
            my $value=GP_Read($device->{NAME},$reading,'');
            next unless grep {$_ eq "$reading: $value" || ($reading eq 'state' && $_ eq $value)} @$events;
            $watch->{$reading}{observed}=GP_ReadingFingerprint($device->{NAME},$reading);
            $updated=1;
        }
        if ($updated) {
            # Completion belongs to this reservation, not to the current display.
            # A contact close may reset pulse_state to idle before the next timer;
            # keep the first validated terminal result across all later updates.
            my $result=GP_ActorResult($actor);
            $actor->{completion}//=$result if defined($result);
        }
    }
    return unless ($device->{TYPE}//'') eq 'ROOMMATE';
    my $request=$c->{helper}{gp}{status_request};
    return if $request && $request->{manual_home} && $request->{manual_home}{$device};
    my $batch=$device->{CHANGED}//$events;
    # Echo attribution needs only zero, one or multiple Home events.
    my $home_events=0;
    for my $event (@$events) {
        next unless $event =~ /\A(?:state: )?home\z/;
        last if ++$home_events==2;
    }
    my $home_state=GP_Read($device->{NAME},'state','') eq 'home';
    # With no normalized view, a mapped 'home' may actually mean absence.
    $home_events=0 if $home_events && !$home_state && $batch==$events
        && GP_Attr($device->{NAME},'eventMap','');
    # ROOMMATE emits lastState with a state transition. setreading can instead
    # emit only the mapped Home value, which may itself have a Reading prefix.
    my $home_evidence=$home_events;
    if (!$home_evidence && $home_state) {
        for my $event (@$batch) {
            next unless $event =~ /\AlastState: /;
            $home_evidence=1;
            last;
        }
    }
    if (!$home_evidence && $home_state && GP_Attr($device->{NAME},'eventMap','')) {
        my $mapped_home=ReplaceEventMap($device->{NAME},'home',1);
        for my $event (@$batch) {
            $home_evidence=$event eq $mapped_home || $event !~ /\A[\w.-]+: /;
            if (!$home_evidence) {
                # Decode the final value with FHEM's user mapping, as notify does.
                # Repeated trigger mapping need not leave the first Home alias.
                my (undef,@plain)=ReplaceEventMap($device->{NAME},[$device->{NAME},$event],0);
                $home_evidence=join(' ',@plain) =~ /\A(?:state:? )?home\z/;
            }
            last if $home_evidence;
        }
    }
    return unless $home_evidence;
    if ($request && $request->{device}==$device && $request->{status} eq 'home'
        && $request->{home_written} && !$request->{home_seen}++) {
        return if $home_events<=1;
    }
    GP_ManualHome($c,$device);
    $request->{manual_home}{$device}=1 if $request;
    return;
}

# GP_SetList: Build the native FHEMWEB Set menu without changing runtime state.
# FHEMWEB obtains its set menu by calling SetFn with "?". Return whitespace-
# separated command:widget entries, never a usage sentence. The native select
# widget decodes '#' as a space in argument combinations. Merely displaying
# this list must not allocate state, reset a journey or open learning reception.
sub GP_SetList {
    my ($hash)=@_;
    my $kind=$hash->{SUBTYPE}//'';
    if ($kind eq 'resident') {
        return GP_UsesSource(GP_Attr($hash->{NAME},'sourceMode','geofency_phone'),'geo')
            ? 'mode:active,debug,disabled,learning webhookPassword:textField learnConfirm:noArg'
            : 'mode:active,debug,disabled';
    }
    return '' unless $kind eq 'controller';
    my @residents=grep {/\A[A-Za-z0-9_.-]+\z/} GP_Residents($hash);
    my @geo=grep {GP_UsesSource(GP_Attr($_,'sourceMode','geofency_phone'),'geo')} @residents;
    my @phone=grep {GP_UsesSource(GP_Attr($_,'sourceMode','geofency_phone'),'phone')} @residents;
    my %choices=(
        applyGeometry=>\@geo,
        debugReset=>[map {($_,$_.'#keepGeometry')} @residents],
        debugPhoneMode=>[map {($_.'#live',$_.'#simulated')} @phone],
        debugPhone=>[map {($_.'#present',$_.'#absent')} @phone],
        debugAdvance=>[],
    );
    return 'mode:active,debug,disabled '.join(' ',map {$_ . (@{$choices{$_}} ? ':select,,'.join(',',@{$choices{$_}}) : ':textField')}
        sort keys %choices);
}

# GeoPresence_Set: Handle user commands that change modes, setup data, or debug state.
sub GeoPresence_Set {
    my ($hash,$name,$command,@args)=@_;
    $command //= '?';
    if ($command eq 'mode') {
        return 'Usage: set '.$name.' mode active|debug|disabled'.(($hash->{SUBTYPE}//'') eq 'resident'?'|learning':'') unless @args==1;
        return GP_SetMode($hash,$args[0]);
    }
    if (($hash->{SUBTYPE}//'') eq 'resident' && $command eq 'learnConfirm') {
        return 'Usage: set '.$name.' learnConfirm' if @args;
        return GP_LearnConfirm(GP_Controller($hash),$name);
    }
    if (($hash->{SUBTYPE}//'') eq 'resident' && $command eq 'webhookPassword') {
        return 'Resident has no Geofency source' unless GP_UsesSource(GP_Attr($name,'sourceMode','geofency_phone'),'geo');
        my $c=GP_Controller($hash);
        return 'Controller unavailable' unless $c && $c->{helper}{gp};
        my $guard=GP_ConfigChangeError($c,$hash); return $guard if $guard;
        return 'Replace the password placeholder before using this command' if @args==1 && $args[0] =~ /\A__.*__\z/;
        return 'Use a random password of 24..128 characters: A-Z a-z 0-9 _ -'
            unless @args==1 && $args[0] =~ /\A[A-Za-z0-9_-]{24,128}\z/;
        open my $random,'<:raw','/dev/urandom' or return 'Random source unavailable';
        my $bytes=''; my $n=read($random,$bytes,16); close $random;
        return 'Random source unavailable' unless defined($n) && $n==16;
        my $salt=unpack('H*',$bytes);
        my $error=GP_StoreAuth($name,$salt.':'.sha256_hex($salt.':'.$args[0]));
        # The preferred key may have changed even if legacy cleanup returned an error.
        delete $GP_AUTH{$name};
        return $error if $error;
        setReadingsVal($hash,'gp_auth_error','',POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now())))
            if GP_Read($name,'gp_auth_error','');
        delete $c->{helper}{gp}{learned}{$name};
        GP_ResetResident($c,$name); GP_UpdateModes($c);
        GP_InvalidateConfig($c);
        return 'Webhook password stored in the FHEM key store';
    }
    return 'Unknown argument, choose one of '.GP_SetList($hash)
        if ($hash->{SUBTYPE}//'') ne 'controller'
            || $command !~ /\A(?:applyGeometry|debugReset|debugPhoneMode|debugPhone|debugAdvance)\z/;
    unless (@args) {
        my %extra=(debugReset=>' [keepGeometry]',debugPhoneMode=>' live|simulated',
            debugPhone=>' present|absent',debugAdvance=>' seconds');
        return "Usage: set $name $command resident".($extra{$command}//'');
    }
    my ($r,$value)=@args;
    return 'Unknown resident' unless GP_Field($r,'SUBTYPE','') eq 'resident' && GP_Field($r,'CONTROLLER','') eq $name;
    my $rt=$hash->{helper}{gp};
    if ($command eq 'applyGeometry') {
        return 'Usage: set controller applyGeometry resident' unless @args==1;
        return GP_ApplyGeometry($hash,$r);
    }
    return 'Debug commands are unavailable during learning; use learnConfirm or set resident mode disabled' if GP_EffectiveMode($hash,$r,0) eq 'learning';
    return 'Resident is disabled' if GP_EffectiveMode($hash,$r,1) eq 'disabled';
    if ($command eq 'debugReset') {
        return 'Usage: set controller debugReset resident [keepGeometry]'
            unless @args==1 || (@args==2 && $value eq 'keepGeometry');
        my $keep_geometry=defined($value) && $value eq 'keepGeometry';
        return 'keepGeometry requires a real-time debug session; use debugReset without keepGeometry after debugAdvance'
            if $keep_geometry && (($rt->{debug}{$r}//{})->{debug_offset}//0)!=0;
        delete $rt->{learning}{$r};
        delete $rt->{learned}{$r} if ($rt->{learned}{$r}//{})->{unbound};
        # Coordinates are reusable setup data, not evidence of a trip. Keep
        # their timestamps and conflict flags intact; all journey state and
        # queued observations are discarded even when geometry is retained.
        delete $rt->{geometry}{debug}{$r} unless $keep_geometry;
        GP_InvalidateConfig($hash,$r,1) unless $keep_geometry;
        $rt->{debug}{$r}=GP_NewState(GP_Now()-31,GP_Mono()-31,$rt->{epoch}.':debug:'.$r.':'.GP_Now(),GP_Attr($r,'sourceMode','geofency_phone'));
        @{$rt->{queue}}=grep {!($_->{debug} && $_->{resident} eq $r)} @{$rt->{queue}};
        return $keep_geometry ? 'Debug session reset; geometry retained; no productive changes' : 'Debug session reset; no productive changes';
    }
    my $phone=GP_UsesSource(GP_Attr($r,'sourceMode','geofency_phone'),'phone');
    return 'Phone source disabled by sourceMode; debugPhoneMode and debugPhone are unavailable'
        if !$phone && $command =~ /\AdebugPhone(?:Mode)?\z/;
    my $s=GP_State($hash,$r,1);
    if ($command eq 'debugPhoneMode') {
        return 'Choose live or simulated' unless defined($value) && $value =~ /\A(?:live|simulated)\z/;
        $s->{phone_mode}=$value; $s->{phone}=GP_NewPhone();
    } elsif ($command eq 'debugPhone') {
        return 'debugPhoneMode must be simulated' unless ($s->{phone_mode}//'') eq 'simulated';
        return 'Choose present or absent' unless defined($value) && $value =~ /\A(?:present|absent)\z/;
        $s->{sim_phone}=$value;
    } elsif ($command eq 'debugAdvance') {
        return 'debugAdvance requires simulated phone or geofency_only and 1..86400 seconds' unless (!$phone || ($s->{phone_mode}//'') eq 'simulated')
            && defined($value) && $value =~ /\A\d+\z/ && $value>=1 && $value<=86400;
        $s->{debug_offset}+=$value;
    }
    return 'Debug state updated; no productive changes';
}

# GP_ReportTime: Format an observed timestamp or an explicit missing-value label.
# Presentation reads snapshots only. Never call GP_State, GP_Rules, GP_Phone,
# GP_ConfirmArrival or a dispatcher from these helpers: a get is not an event.
sub GP_ReportTime {
    my ($time)=@_;
    return 'Not observed' unless defined($time) && GP_Number($time) && $time>0;
    return POSIX::strftime('%Y-%m-%d %H:%M:%S %Z',localtime($time));
}

# GP_ReportDuration: Format an elapsed duration for human-readable reports.
sub GP_ReportDuration {
    my ($seconds)=@_;
    return 'Unknown' unless defined($seconds) && GP_Number($seconds);
    $seconds=0 if $seconds<0;
    return sprintf('%.1f s',$seconds) if $seconds<60;
    return sprintf('%d min %02d s',int($seconds/60),int($seconds)%60) if $seconds<3600;
    return sprintf('%d h %02d min',int($seconds/3600),int($seconds/60)%60);
}

# GP_ReportValue: Normalize report text to Unicode and remove control characters.
sub GP_ReportValue {
    my ($text)=@_;
    $text//='';
    $text=decode('UTF-8',$text) if !$unicodeEncoding && !utf8::is_utf8($text);
    $text =~ s/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/ /g;
    return $text;
}

# GP_ReportEscape: Escape report content for HTML, including non-ASCII characters.
sub GP_ReportEscape {
    my ($text)=@_;
    $text=GP_ReportValue($text);
    $text =~ s/&/&amp;/g; $text =~ s/</&lt;/g; $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g; $text =~ s/'/&#39;/g;
    # Some FHEMWEB versions encode Unicode only when compressing the response.
    # Numeric entities render identically with or without gzip in either mode.
    $text =~ s/([^\x00-\x7f])/sprintf('&#x%X;',ord($1))/eg;
    return $text;
}

# GP_ReportJSON: Encode report data as JSON safe for the selected FHEM transport.
sub GP_ReportJSON {
    my ($value,$web)=@_;
    my $json=$web ? JSON::PP->new->canonical->ascii->encode($value) : $GP_JSON->encode($value);
    # FHEMWEB inserts even a JSON response into a <pre> using .html().
    # Escapes preserve decoded values and prevent executable markup.
    $json =~ s/([<>&])/sprintf('\\u%04x',ord($1))/eg if $web;
    return $json;
}

# GP_ReportCell: Render an escaped report cell and link known device names in FHEMWEB.
sub GP_ReportCell {
    my ($text)=@_;
    my $escaped=GP_ReportEscape($text);
    if (defined($text) && GP_Name($text) && exists($defs{$text}) && defined($FW_ME)) {
        return '<a href="'.GP_ReportEscape($FW_ME.($FW_subdir//'').'?detail='.$text).'">'.$escaped.'</a>';
    }
    return $escaped;
}

# GP_ReportLine: Format one complete text-report value with an optional prefix.
sub GP_ReportLine {
    my ($text,$prefix)=@_;
    # One complete value per line; the terminal controls any visual wrapping.
    return ($prefix//'').GP_ReportValue($text)."\n";
}

# GP_RenderReport: Render structured report sections as escaped HTML or plain text.
sub GP_RenderReport {
    my ($report,$html)=@_;
    my $title=$report->{title}//'GeoPresence';
    # jQuery UI otherwise focuses the first device link and scrolls past the summary.
    my $out=$html ? '<html><div class="gp-report" tabindex="-1" autofocus style="width:min(64rem,calc(100vw - 4rem));max-width:100%;box-sizing:border-box;white-space:normal;overflow-wrap:anywhere;line-height:1.45;outline:none">'
        : '';
    if (length($report->{banner}//'')) {
        my $banner='=== '.$report->{banner}.' ===';
        $out.=$html ? '<p><strong>'.GP_ReportEscape($banner).'</strong></p>' : "$banner\n";
    }
    $out.=$html ? '<h3>'.GP_ReportEscape($title).'</h3>' : GP_ReportLine($title);
    for my $key (qw(subtitle context notice lead)) {
        next unless length($report->{$key}//'');
        $out.=$html ? '<p>'.($key eq 'lead'?'<strong>':'').GP_ReportEscape($report->{$key})
            .($key eq 'lead'?'</strong>':'').'</p>' : GP_ReportLine($report->{$key});
    }
    for my $section (@{$report->{sections}//[]}) {
        my $heading=$section->{heading}//'';
        # An explicit collapsed value enables folding; false starts expanded.
        my $collapsible=exists $section->{collapsed};
        if ($html) {
            $out.=$collapsible ? '<details'.($section->{collapsed} ? '' : ' open').' style="margin:1em 0"><summary style="cursor:pointer;font-weight:bold">'.GP_ReportEscape($heading).'</summary>'
                : '<h4>'.GP_ReportEscape($heading).'</h4>';
        } elsif (length $heading) { $out.="\n".uc($heading)."\n".('-' x length($heading))."\n"; }
        if (my $note=$section->{note}) {
            $out.=$html ? '<p>'.GP_ReportEscape($note).'</p>' : GP_ReportLine($note,'  ');
        }
        if (my $commands=$section->{commands}) {
            $out.=$html ? '<pre style="white-space:pre-wrap;overflow-wrap:anywhere">'.join("\n",map {GP_ReportEscape($_)} @$commands).'</pre>'
                : join("\n",@$commands)."\n";
        }
        my $rows=$section->{rows}//[];
        my $columns=$section->{columns}//['Item','Status'];
        if (@$rows) {
            my $width=0;
            for my $row (@$rows) {
                my $length=length(GP_ReportValue($row->[0]));
                $width=$length if $length>$width;
            }
            $out.='<table class="block" style="width:100%;table-layout:fixed;border-collapse:collapse"><thead><tr>'
                .join('',map {'<th style="text-align:left;padding:.4em;vertical-align:top">'.GP_ReportEscape($_).'</th>'} @$columns).'</tr></thead><tbody>' if $html;
            my $first_row=1;
            for my $row (@$rows) {
                if ($html) {
                    $out.='<tr>'.join('',map {'<td style="padding:.4em;vertical-align:top;white-space:normal;overflow-wrap:anywhere">'.GP_ReportCell($_).'</td>'} @$row).'</tr>';
                } elsif (@$columns==2) {
                    my $label=GP_ReportValue($row->[0]);
                    my $prefix='  '.sprintf('%-*s',$width,$label).' : ';
                    $out.=GP_ReportLine($row->[1],$prefix);
                } else {
                    $out.="\n" unless $first_row;
                    $out.=GP_ReportLine($row->[0]);
                    $out.=GP_ReportLine($row->[$_],'  '.$columns->[$_].': ') for 1..$#$columns;
                }
                $first_row=0;
            }
            $out.='</tbody></table>' if $html;
        }
        $out.='</details>' if $html && $collapsible;
    }
    $out.='</div></html>' if $html;
    return $out;
}

# GP_ReportTrace: Build a newest-first history section from previously recorded decisions.
sub GP_ReportTrace {
    my ($trace,$limit,$all)=@_;
    my @rows;
    for my $row (reverse @{$trace//[]}) {
        next if !$all && $row->{diagnostic_only};
        my $reason=$row->{reason}//'Unknown';
        $reason.='; return permission '.($row->{departure_armed}?'granted':'not granted') if exists $row->{departure_armed};
        $reason.='; '.$row->{confirmation} if length($row->{confirmation}//'');
        my $cause='Not recorded';
        for my $key (qw(rule zone source target)) {
            next unless defined($row->{$key}) && length($row->{$key});
            $cause=$row->{$key}; last;
        }
        push @rows,[GP_ReportTime($row->{time}),$reason,$cause];
        last if @rows>=$limit;
    }
    return {heading=>'Recent decisions',columns=>['Time','Decision','Rule / source'],rows=>\@rows,
        note=>@rows ? 'Newest first. This is recorded history, not a new evaluation.' : 'No decisions recorded in this session.'};
}

# GP_ReportActorResult: Translate stored actor result codes into readable labels.
sub GP_ReportActorResult {
    my ($result)=@_;
    my %labels=(not_requested=>'No request in this session',dispatch_started=>'Dispatch started',
        pending=>'Request sent; awaiting feedback',shared=>'Sharing a pending request; awaiting feedback',
        confirmed=>'Opening confirmed',uncertain=>'Feedback timeout; outcome uncertain',failed=>'Command failed',
        suppressed=>'Opening suppressed by actuator state',already_satisfied=>'Actuator was already open or opening');
    return $labels{$result//'not_requested'}//$result;
}

# GP_ReportResident: Build a resident report from recorded decisions and current source Readings.
sub GP_ReportResident {
    my ($c,$r,$s,$cfg,$debug,$errors,$now,$mono,$value)=@_;
    my $mode=GP_EffectiveMode($c,$r,0);
    my $paused=!$debug && $mode ne 'active';
    my $trip=$s->{trip}//{}; my $phone=$s->{phone}//{}; my $arrival=$s->{arrival};
    my $phase=$s->{phase}//'unknown';
    my $armed=$trip->{armed} && !$s->{conflict};
    my $remaining=$arrival ? $arrival->{due_mono}-$mono:0;
    my $lead= $mode eq 'learning' ? 'Learning setup data — no presence evaluation or actions' : !@{$errors//[]} ? '' : 'Configuration invalid — evaluation suspended';
    $lead||= $mode eq 'disabled' ? 'Disabled — no new actions'
        : $paused ? 'Production evaluation paused — displayed state is not being processed'
        : !$value->{initialized} ? 'Not initialized — no observations processed in this view'
        : $cfg->{sourceMode} eq 'phone_only' ? 'Phone presence only — no automatic opening'
        : !$cfg->{geometry_ready} ? 'No opening planned — location geometry is not ready'
        : $s->{conflict} ? 'No opening planned — conflicting observations'
        : $arrival ? ($remaining>0 ? 'Arrival pending — confirmation in '.GP_ReportDuration($remaining) : 'Arrival confirmation due — waiting for event processing')
        : $armed ? 'Departure confirmed — waiting for return'
        : keys(%$trip) ? ($cfg->{sourceMode} eq 'geofency_only'
            ? 'Departure not confirmed — additional distance evidence required'
            : 'Departure not confirmed — waiting for qualified phone absence')
        : $phase eq 'home' ? 'At home — no new opening planned'
        : 'No opening planned — departure not confirmed';
    my $report={title=>'GeoPresence · '.GP_LogResident($r),banner=>$debug?'DEBUG':'PRODUCTION',
        subtitle=>$r.' · Snapshot '.GP_ReportTime($now),
        notice=>$debug?'Simulation only — no device commands, messages or ROOMMATE changes.':'',
        lead=>$lead,sections=>[]};
    my @summary=(['Resident mode',GP_Mode($r)],['Controller mode',GP_Mode($c->{NAME})],['Effective mode',$mode],
        ['Mode reason',GP_ModeReason($c,$r)],['Source profile',$cfg->{sourceMode}],['Presence',$value->{initialized}?ucfirst($phase):'Not initialized'],
        [$debug?'Simulated status':'ROOMMATE status',$debug ? ($s->{desired_status}//($phase eq 'home'?'home':'Not set')) : GP_Read($cfg->{roommate},'state','unknown')],
        ['Departure',$armed ? 'Confirmed: '.($trip->{away_reason}//'current trip') : 'Not confirmed'],
        ['Trip',keys(%$trip) ? ucfirst($trip->{scope}//'unknown') : 'No active trip'],
        ['Phone',GP_UsesSource($cfg->{sourceMode},'phone')
            ? ucfirst($phone->{state}//'unknown').' ('.($debug && ($s->{phone_mode}//'live') eq 'simulated' ? 'simulated' : $phone->{health}//'unknown').')' : 'Disabled by source profile; no phone fallback'],
        ['Motion',$arrival ? ucfirst($arrival->{motion}) : ucfirst(GP_ArrivalMotion($s,$cfg,$now))]);
    push @summary,['ROOMMATE update error',$s->{roommate_error}] if $s->{roommate_error};
    if ($arrival) {
        push @summary,['Home entry received',GP_ReportTime($arrival->{started})],
            ['Confirmation due',GP_ReportTime($arrival->{deadline}).' — wait '.GP_ReportDuration($arrival->{wait})],
            ['Remaining at snapshot',GP_ReportDuration($remaining)];
    } elsif (defined($trip->{home_exit})) {
        push @summary,['Home exit',GP_ReportTime($trip->{home_exit})];
        push @summary,['Phone absence qualification',GP_ReportDuration($mono-$phone->{negative_since}).' / '.GP_ReportDuration($cfg->{phone_absence_window})]
            if !$armed && defined($phone->{negative_since});
    }
    my $resume=$s->{resume}//{};
    push @summary,['Restart recovery',ucfirst($resume->{status}).': '.$resume->{reason}]
        if !$debug && ($resume->{status}//'none') ne 'none';
    push @{$report->{sections}},{id=>'status',heading=>'Status',rows=>\@summary,
        note=>$debug ? 'Simulation only. No productive ROOMMATE changes, actuator commands or messages.' : 'Presence alone does not confirm an opening request.'};
    push @{$report->{sections}},{%{GP_ReportTrace($s->{trace},5,0)},id=>'history',collapsed=>0};
    my @actions;
    for my $rule (@{$cfg->{rules}}) {
        next unless $rule->{trigger} eq 'arrival' && GP_IsOpening($rule->{type});
        my $garage=$rule->{type} eq 'garage_open';
        my $eligible=$arrival ? $arrival->{vehicle_eligible}:GP_VehicleEligible($s,$cfg,$now);
        my $assessment= $mode eq 'disabled' ? 'Disabled'
            : $paused ? 'Production evaluation paused'
            : @{$errors//[]} ? 'Blocked by invalid configuration'
            : !$value->{initialized} ? 'State not initialized; no opening permission'
            : !$cfg->{geometry_ready} ? 'Blocked by missing or inconsistent geometry'
            : !($garage?$cfg->{allowGarage}:$cfg->{allowDoor}) ? 'Resident has no permission'
            : !$armed ? 'No qualified active trip'
            : ($rule->{arrivalFilter}//'any') eq 'vehicle' && !$eligible ? 'No qualifying car or remote evidence, or current walking/cycling'
            : length($rule->{afterExit}//'') && !defined(GP_ExitEvidence($s,$rule->{afterExit},$arrival ? $arrival->{event}{time}:$now)) ? 'Required prior exit not observed in this trip'
            : $arrival ? 'Eligible after arrival confirmation; no request sent yet' : 'Waiting for a valid return';
        my $previous=$s->{$garage?'garage_result':'door_result'};
        $assessment='No new request planned; latest result: '.GP_ReportActorResult($previous)
            if !$armed && !$arrival && $phase eq 'home' && defined($previous) && $previous ne 'not_requested' && !@{$errors//[]} && $mode ne 'disabled' && !$paused;
        push @actions,[$garage?'Garage':'Front door',$rule->{name},$assessment];
    }
    push @{$report->{sections}},{id=>'actions',heading=>'Arrival actions',collapsed=>1,columns=>['Action','Rule','Current assessment'],rows=>\@actions,
        note=>@actions ? 'Actuator conditions are checked before dispatch. Eligibility does not mean a command has been sent.' : 'No enabled arrival-opening rules apply to this resident.'};
    my @rules=map {[$_->{name},$_->{trigger},$_->{trigger} eq 'arrival' ? 'Confirmed return'
        : length($_->{group}//'') ? 'Group: '.$_->{group} : join(', ',@{$_->{locations}}),
        $_->{afterExit} || 'None',$_->{arrivalFilter}//'any',$_->{action}]} @{$cfg->{rules}};
    push @{$report->{sections}},{id=>'rules',heading=>'Configured rules',collapsed=>1,
        columns=>['Rule','Trigger','Locations / group','Required prior exit','Arrival filter','Action'],rows=>\@rules,
        note=>'Group membership and prior exits belong to this resident only. A required prior exit must precede the event in the current trip.'};
    my @sensor_rows;
    if (!GP_UsesSource($cfg->{sourceMode},'phone')) {
        push @sensor_rows,['Not used','Disabled','Source profile geofency_only','No phone readings are evaluated'];
    } elsif ($debug && ($s->{phone_mode}//'live') eq 'simulated') {
        push @sensor_rows,['All simulated sensors',$s->{sim_phone}//'absent','Simulation','No physical measurement'];
    } else {
        my $samples=GP_PhoneSamples($cfg,$now);
        for my $name (@{$cfg->{proxies}}) {
            my $v=$samples->{$name};
            push @sensor_rows,[$name,$v->{value}//'unknown',$v->{healthy}?'Source reports healthy':'Source unavailable or inconsistent',GP_ReportTime($v->{time})];
        }
    }
    push @{$report->{sections}},{id=>'sensors',heading=>'Phone sensors',collapsed=>1,columns=>['Sensor','State','Source health','Observed'],rows=>\@sensor_rows,
        note=>GP_UsesSource($cfg->{sourceMode},'phone')
            ? 'Current source readings; the summary above is the last processed phone state. Last positive observation: '.GP_ReportTime($phone->{latest})
            : 'Home exit and elapsed time alone cannot authorize opening. Additional distance evidence is required. If the Home webhook is lost, there is no phone fallback.'};
    my @zones;
    for my $name (sort keys %{$cfg->{zones}}) {
        my $zone=$cfg->{zones}{$name};my $observation=($s->{zones}//{})->{$name};
        push @zones,[$name,$zone->{role},join(', ',@{$zone->{groups}}) || 'None',$observation ? ($observation->{entry}?'Entered':'Left').' — '.GP_ReportTime($observation->{time}) : 'Not observed',
            GP_HasGeometry($zone) ? $zone->{radius}.' m; '.($zone->{blocked}?'conflicting':'known') : 'Not learned'];
    }
    my @missing_geometry=GP_MissingGeometry($cfg);
    push @{$report->{sections}},{id=>'locations',heading=>'Locations and geometry',collapsed=>1,columns=>['Location','Function','Groups','Last observation','Radius / geometry'],rows=>\@zones,
        note=>!GP_UsesSource($cfg->{sourceMode},'geo') ? 'Locations are not used by phone_only; Geo webhooks and learning are unavailable.'
            : @{$cfg->{geometry_errors}//[]} ? join('; ',@{$cfg->{geometry_errors}})
            : @missing_geometry ? 'Opening geometry is ready, but other registered locations still lack geometry: '.join(', ',@missing_geometry).'. The automatic test application also needs these locations.'
            : 'Geometry is available for all registered locations; opening geometry checks passed.'};
    my @results;
    for my $kind (qw(door garage)) {
        push @results,['Latest '.$kind.' result',GP_ReportActorResult($s->{$kind.'_result'})];
    }
    my $actors=($c->{helper}{gp}//{})->{actors}//{};
    for my $target (sort keys %$actors) {
        my $actor=$actors->{$target};
        next unless exists(($actor->{waiters}//{})->{$r});
        push @results,[$target,($debug?'Existing production request: ':'').'Awaiting feedback since '.GP_ReportTime($actor->{start})];
    }
    push @{$report->{sections}},{id=>'feedback',heading=>'Actuator feedback',collapsed=>1,rows=>\@results,
        note=>'Results describe previously requested operations. They do not create permission for another opening.'};
    my @technical=(['Controller',$c->{NAME}],['Resident',$r],['ROOMMATE',$cfg->{roommate}],
        ['Session started',GP_ReportTime($s->{start})],['Session ID',$s->{generation}//'Not initialized'],
        ['Trip ID',$trip->{id}//'None'],['Last decision',$s->{last_reason}//'No decision recorded'],
        ['Last observation',GP_ReportTime($s->{last_observed})],['Last received',GP_ReportTime($s->{last_received})]);
    push @technical,map {['Configuration error',$_]} @{$errors//[]};
    push @{$report->{sections}},{id=>'technical',heading=>'Technical details',collapsed=>1,rows=>\@technical,
        note=>'Full machine-readable state is available with format=json. Only a validated qualified trip checkpoint can resume; a new return is still required.'};
    if ($debug) {
        push @{$report->{sections}},{id=>'readiness',heading=>'Debug readiness',rows=>[
            ['Debug ready',$value->{debug_ready}?'Yes':'No: '.join('; ',@{$value->{debug_blockers}})],
            ['Geometry ready',$cfg->{geometry_ready}?'Yes':'No'],
            ['Missing location geometry',@missing_geometry ? join(', ',@missing_geometry):'None'],
            ['Geometry-preserving reset','Supported'],['Test webhook isolation','Supported']],
            note=>'Opening geometry checks do not require ordinary places. Automatic tests need every registered location. Readiness does not grant opening permission.'};
    }
    return $report;
}

# GP_GetReport: Convert command data into structured, human-readable report sections.
sub GP_GetReport {
    my ($hash,$command,$args,$value,$limit,$prepared_cfg)=@_;
    my $c=GP_Controller($hash);my $now=GP_Now();
    my $report={title=>'GeoPresence · '.$command,sections=>[]};
    if ($command eq 'validate') {
        $report->{title}=$value->{valid}?'OK: configuration valid':'Configuration invalid';
        $report->{lead}=@{$value->{warnings}}?'Review the following notices.':'Validation does not execute actions.';
        for my $group (['Errors','errors'],['Notices','warnings']) {
            next unless @{$value->{$group->[1]}};
            my %seen;
            my @messages=grep {!$seen{$_}++} @{$value->{$group->[1]}};
            push @{$report->{sections}},{heading=>$group->[0],columns=>['Device','Finding'],rows=>[
                map {/\A([A-Za-z0-9_.-]+):\s*(.*)\z/s ? [$1,$2] : [$c->{NAME},$_]} @messages]};
        }
    } elsif ($command eq 'locationCommands') {
        $report->{sections}=[{heading=>'Commands to copy',commands=>$value->{commands},note=>'Review and execute these commands yourself; this query changes no devices.'}];
    } elsif ($command eq 'learnedLocations') {
        $report->{subtitle}=$args->[0];
        $report->{lead}=@$value ? scalar(@$value).' captured locations; definitions are not created automatically.' : 'No locations captured yet.';
        my $learned=GP_Learned($c,$args->[0]);
        my $receiving=$c->{helper}{gp}{learning}{$args->[0]};
        my $status=$learned->{expired} && !$learned->{confirmed} ? 'Expired; resident disabled' : !$receiving ? 'Stopped' : GP_Mono()>$learned->{until} ? 'Expired; no further webhooks accepted' : 'Receiving test webhooks';
        $report->{sections}=[{heading=>'Device learning',rows=>[
            ['Device ID',length($learned->{device}) ? $learned->{device} : 'Waiting for first authenticated test webhook'],
            ['Binding',$learned->{unbound} ? 'Not configured; confirm with set resident learnConfirm' : 'Configured'],
            ['Confirmation',$learned->{confirmed}?'Confirmed':'Awaiting set resident learnConfirm'],['Reception',$status]],
            note=>'learnConfirm confirms captured setup data and leaves the resident disabled. An existing deviceId is never replaced. Set mode disabled to cancel unconfirmed learning; save after completing setup.'},
            {heading=>'Captured locations',columns=>['Number','Name','Zone ID','Radius','Received'],rows=>[
            map {['@'.$_->{number},$_->{name},$_->{id},(($_->{geometry}//{})->{radius}//'?').' m',GP_ReportTime($_->{time})]} @$value]}];
    } elsif ($command eq 'logStatus') {
        $report->{lead}=length($value->{error})?'Diagnostic write error recorded':'No diagnostic write error recorded';
        $report->{sections}=[{heading=>'Log output',rows=>[
            ['Normal output','FHEM log'],['Normal verbosity',$value->{verbose}],['Diagnostic file',length($value->{file})?$value->{file}:'Not configured'],
            ['Diagnostic setting',$value->{debugLog}],['Simulation diagnostics',$value->{debugEnabled}?'Enabled':'Disabled'],
            ['Learning diagnostics',$value->{learningEnabled}?'Enabled':'Disabled'],
            ['Production diagnostics',$value->{activeEnabled}?'Enabled':'Disabled'],['Diagnostic limit',$value->{rate_limit}.' entries / minute'],
            ['Last write error',$value->{error}||'None']],note=>'Enabled describes configuration, not a write-permission test. This query writes no log entries.'}];
    } elsif ($command eq 'timerStats') {
        $report->{sections}=[{heading=>'Timer work',rows=>[map {[$_->[0],$value->{$_->[1]}.' ms']} ['Last','last_ms'],['Mean','mean_ms'],['Maximum','max_ms']]},
            {heading=>'Delayed starts',rows=>[map {[$_->[0],$value->{$_->[1]}.' ms']} ['Last','last_lag_ms'],['Maximum','max_lag_ms']],note=>'Start delay is separate from work performed by GeoPresence.'},
            {heading=>'Counters',rows=>[['Runs',$value->{runs}],['Slow runs',$value->{slow_runs}],['Late starts',$value->{late_runs}],
                ['Device scans (last run)',$value->{last_device_scans}],['Configuration builds (last run)',$value->{last_config_builds}],['Last start',GP_ReportTime($value->{last_started_at})]]}];
        if (my $run=$value->{worst_run}) {
            push @{$report->{sections}},{heading=>'Slowest profiled run',rows=>[
                ['Started',GP_ReportTime($run->{started_at})],['Elapsed',$run->{elapsed_ms}.' ms'],['Process CPU (approx.)',$run->{cpu_ms}.' ms'],
                ['Start delay',$run->{start_lag_ms}.' ms'],['Largest self time',$run->{slowest_phase}],['Device / context',$run->{slowest_target}],
                ['Self time',$run->{slowest_self_ms}.' ms'],['Profiling since',GP_ReportTime($value->{profile_started_at})]],
                note=>'Elapsed time includes synchronous FHEM callbacks and operating-system pauses. CPU time has platform-dependent resolution; low CPU does not identify a particular wait. Older aggregate maxima may predate profiling.'};
            my @phases=@{$run->{phases}}; splice @phases,6 if @phases>6;
            push @{$report->{sections}},{heading=>'Phase breakdown of slowest run',columns=>['Phase','Device / context','Calls','Elapsed','Self'],
                rows=>[map {[$_->{phase},$_->{target},$_->{calls},$_->{elapsed_ms}.' ms',$_->{self_ms}.' ms']} @phases],
                note=>'Largest six self-time totals. Elapsed includes nested measured calls; Self excludes them. Do not add inclusive elapsed times. Full breakdown: format=json.'};
        }
        for my $group ([recent_slow=>'Recent slow runs'],[recent_late=>'Recent delayed starts']) {
            my @runs=reverse @{$value->{$group->[0]}};
            splice @runs,5 if @runs>5;
            push @{$report->{sections}},{heading=>$group->[1],columns=>['Started','Work','Start delay','Largest self time','Device / context'],
                rows=>[map {[GP_ReportTime($_->{started_at}),$_->{elapsed_ms}.' ms',$_->{start_lag_ms}.' ms',$_->{slowest_phase},$_->{slowest_target}]} @runs],
                note=>@runs ? 'Newest five entries; format=json retains up to twelve with full phase timings. A delayed start alone does not establish GeoPresence as the cause.' : 'No matching profiled runs recorded.'};
        }
    } elsif ($command eq 'debugTrace') {
        $report->{banner}='DEBUG';
        $report->{subtitle}=$args->[0]//$hash->{NAME};
        $report->{lead}='Simulation history — no productive actions';
        $report->{sections}=[GP_ReportTrace($value,$limit//20,1)];
        $report->{sections}[0]{note}='Showing up to '.($limit//20).' newest entries of '.scalar(@$value).'. Use limit=100 or format=json for more history.';
    } else {
        my $r=$args->[0]// $hash->{NAME};
        my $debug=$value->{view} eq 'debug';
        my $s=$value->{state};
        my $cfg=$prepared_cfg;
        $report=GP_ReportResident($c,$r,$s,$cfg,$debug,$value->{errors},
            $value->{snapshot_at},GP_Mono()+($debug?($s->{debug_offset}//0):0),$value);
    }
    return $report;
}

# GP_GetList: Build the native FHEMWEB Get menu for the selected device.
# Use FHEMWEB's native select widget. '#' is decoded to an argument separator
# by fhemweb.js, just as it is for the controller's set commands.
sub GP_GetList {
    my ($hash)=@_;
    my $c=GP_Controller($hash);
    my @choices=($hash->{SUBTYPE}//'') eq 'resident' ? ('prod','debug')
        : $c ? map {($_,$_.'#prod',$_.'#debug')} grep {/\A[A-Za-z0-9_.-]+\z/} GP_Residents($c) : ();
    return 'validate learnedLocations locationCommands debugTrace explain:'
        .(@choices ? 'select,'.join(',',@choices) : 'textField').' logStatus timerStats';
}

# GeoPresence_Get: Serve read-only Get commands as text, HTML, or JSON.
sub GeoPresence_Get {
    my ($hash,$name,$command,@args)=@_;
    $command//='?';
    return 'Unknown argument, choose one of '.GP_GetList($hash)
        if $command eq '?';
    my $web=(($hash->{CL}//{})->{TYPE}//'') eq 'FHEMWEB';
    # FHEMWEB's addLinks regex also rewrites HTML attributes and JSON strings.
    # Our HTML links are escaped explicitly; JSON must remain machine-readable.
    delete $FW_webArgs{addLinks} if $web;
    my ($format,$limit,$error);my @positional;
    for my $arg (@args) {
        if ($arg =~ /\Aformat=(.*)\z/) {
            my $requested=$1;
            $error='Choose format=json, format=text or format=html (once)' if defined($format) || $requested !~ /\A(?:json|text|html)\z/;
            $format=$requested;
        } elsif ($arg =~ /\Alimit=(.*)\z/) {
            my $requested=$1;
            $error='limit requires debugTrace and an integer from 1 to 1000 (once)' if defined($limit) || $command ne 'debugTrace' || $requested !~ /\A[1-9][0-9]{0,3}\z/ || $requested>1000;
            $limit=$requested;
        } else {push @positional,$arg;}
    }
    my %counts=(logStatus=>0,timerStats=>0,validate=>1,learnedLocations=>1,locationCommands=>4,debugTrace=>1);
    $error='Too many arguments; optional output: format=json|text|html' if exists($counts{$command}) && @positional>$counts{$command};
    if ($command eq 'explain') {
        my $resident=($hash->{SUBTYPE}//'') eq 'resident';
        unshift @positional,$name if $resident && (!@positional || $positional[0] =~ /\A(?:prod|debug)\z/);
        $error='Usage: get '.$name.' explain '.($resident?'[resident]':'resident').' [prod|debug] [format=json|text|html]'
            if @positional>2 || (@positional>1 && $positional[1] !~ /\A(?:prod|debug)\z/);
    }
    $format//= $web?'html':'text';
    my ($value,$data_error,$cfg)=$error ? (undef,$error):GP_GetData($hash,$name,$command,@positional);
    if ($data_error) {
        return GP_ReportJSON({error=>$data_error},$web) if $format eq 'json';
        my $text=$web || $format eq 'html' ? GP_RenderReport({title=>'GeoPresence',lead=>$data_error},1) : $data_error;
        return $unicodeEncoding ? $text : encode('UTF-8',$text);
    }
    if ($command eq 'debugTrace' && $format eq 'json' && defined $limit && @$value>$limit) {
        $value=[@$value[(@$value-$limit)..$#$value]];
    }
    if ($format eq 'json') {
        return GP_ReportJSON($value,$web);
    }
    my $report=GP_GetReport($hash,$command,\@positional,$value,$limit,$cfg);
    my $text= $command eq 'locationCommands' && $format eq 'text' ? join("\n",@{$value->{commands}})
        : GP_RenderReport($report,$format eq 'html');
    # Explicit text in FHEMWEB still needs a safe, wrapping preformatted block.
    if ($web && $format eq 'text') {
        $text=join("\n",map {GP_ReportEscape($_)} split /\n/,$text);
        $text='<html><pre style="max-width:80vw;white-space:pre-wrap;overflow-wrap:anywhere">'.$text.'</pre></html>';
    }
    return $unicodeEncoding ? $text : encode('UTF-8',$text);
}

# GP_GetData: Collect report data without creating journey state or planning actions.
sub GP_GetData {
    my ($hash,$name,$command,@args)=@_;
    my $c=GP_Controller($hash);
    return (undef,'Controller unavailable') unless $c;
    if ($command eq 'logStatus') {
        return ({file=>GP_LogPath($c),verbose=>GP_Attr($c->{NAME},'verbose',GP_Attr('global','verbose',3)),
            debugLog=>GP_Attr($c->{NAME},'debugLog','auto'),normal_log=>'FHEM',
            debugEnabled=>length(GP_LogPath($c)) && GP_DebugLogEnabled($c,{mode=>'debug'}) ? 1:0,
            learningEnabled=>length(GP_LogPath($c)) && GP_DebugLogEnabled($c,{mode=>'learning'}) ? 1:0,
            activeEnabled=>length(GP_LogPath($c)) && GP_DebugLogEnabled($c,{mode=>'active'}) ? 1:0,
            error=>$c->{helper}{gp_log_error}//'',rate_limit=>300});
    }
    if ($command eq 'timerStats') {
        my $stats=$c->{helper}{gp_timer_stats}//{};
        my %view=map {$_=>$stats->{$_}//0} qw(runs slow_runs late_runs last_device_scans last_config_builds);
        $view{$_}=0+sprintf('%.3f',$stats->{$_}//0) for qw(last_ms max_ms last_lag_ms max_lag_ms last_started_at last_cpu_ms profile_started_at);
        $view{mean_ms}=0+sprintf('%.3f',($stats->{total_ms}//0)/($stats->{runs}||1));
        $view{$_}=GP_TimerSampleView($stats->{$_}) for qw(last_run worst_run worst_late_run);
        $view{$_}=[map {GP_TimerSampleView($_)} @{$stats->{$_}//[]}] for qw(recent_slow recent_late);
        return (\%view);
    }
    if ($command eq 'validate') {
        my @errors=GP_Validate($c,$args[0],0);
        return ({valid=>0,errors=>\@errors,warnings=>[]}) if @errors;
        my @res=defined($args[0]) ? ($args[0]) : GP_Residents($c);
        my @geometry;
        my @places;
        my @unused;
        for my $r (@res) {
            my $debug=GP_EffectiveMode($c,$r,0) ne 'active';
            my $cfg=GP_Config($c,$r,$debug);
            push @geometry,@{$cfg->{geometry_errors}};
            my @missing=grep {$cfg->{zones}{$_}{role} eq 'place'} GP_MissingGeometry($cfg);
            push @places,"$r: geometry not yet available for registered places: ".join(', ',@missing)
                .($debug ? '. Debug data; send Geofency test webhooks before testing.'
                    : '. Production data; confirm reviewed debug geometry with applyGeometry before activation, or wait for real Geofency observations.')
                .' Configuration remains valid.' if @missing;
            my @keys=grep {exists($attr{$r}{$_}) && !GP_ResidentAttrEnabled($cfg->{sourceMode},$_)} @{$GP_ATTRS{resident}};
            push @unused,"$r: ".join(', ',@keys)." not used by $cfg->{sourceMode}; remove unused attributes explicitly" if @keys;
            if ($cfg->{sourceMode} eq 'geofency_only') {
                my ($home)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{home}//[]};
                my ($outer)=map {$cfg->{zones}{$_}} @{$cfg->{roles}{outer}//[]};
                push @unused,"$r: outer boundary is too close to Home for departure evidence; use a sufficiently distant location"
                    if GP_HasGeometry($home) && GP_HasGeometry($outer)
                        && $outer->{radius}-GP_Distance($outer,$home)-$home->{radius}<=$cfg->{departure_margin};
            }
        }
        return ({valid=>1,errors=>[],warnings=>[
            (@geometry ? 'Opening unavailable until geometry is ready: '.join('; ',@geometry):()),@places,@unused]});
    }
    if ($command eq 'learnedLocations' || $command eq 'locationCommands') {
        my ($r,$id,$role,$target)=@args;
        return (undef,'Specify a resident device') unless GP_Field($r,'SUBTYPE','') eq 'resident' && GP_Field($r,'CONTROLLER','') eq $c->{NAME};
        my $learned=GP_Learned($c,$r);
        return (undef,'No current learning data; use set resident mode learning and send an isTest=true webhook') unless $learned;
        return ([sort {$a->{number}<=>$b->{number}} values %{$learned->{zones}}]) if $command eq 'learnedLocations';
        return (undef,'Confirm learning with set resident learnConfirm before creating locations') unless $learned->{confirmed};
        return (undef,'Usage: get controller locationCommands resident zoneId-or-@number home|outer|approach|place newDeviceName')
            unless @args==4 && defined($id) && (GP_Id($id) || $id =~ /\A\@[1-9][0-9]?\z/)
                && defined($role) && $role =~ /\A(?:home|outer|approach|place)\z/ && GP_Name($target);
        if ($id =~ /\A\@(\d+)\z/) {
            my ($z)=grep {$_->{number}==$1} values %{$learned->{zones}};
            return (undef,'Learning number not found; see learnedLocations') unless $z;
            $id=$z->{id};
        }
        return (undef,'Location not observed for this resident; see learnedLocations') unless $learned->{zones}{lc $id};
        return (undef,'Device name already exists; choose a new name') if exists $defs{$target};
        return ({commands=>["define $target GeoPresence location $r $role","attr $target zoneId ".lc($id)]});
    }
    return (undef,'Unknown argument, choose one of '.GP_GetList($hash)) unless $command =~ /\A(?:debugTrace|explain)\z/;
    my $r=$args[0]//(($hash->{SUBTYPE}//'') eq 'resident' ? $name:'');
    return (undef,'Specify a resident device') unless GP_Field($r,'SUBTYPE','') eq 'resident' && GP_Field($r,'CONTROLLER','') eq $c->{NAME};
    my $rt=$c->{helper}{gp}//{};
    if ($command eq 'debugTrace') { return ((($rt->{debug}//{})->{$r}//{})->{trace}//[]); }
    my $mode=GP_EffectiveMode($c,$r,0);
    my $view=($args[1]//'prod') eq 'debug'?'debug':'production';
    my $debug=$view eq 'debug'; my $pool=$debug?'debug':'prod';
    my $s=($rt->{$pool}//{})->{$r};
    my $cfg=GP_Config($c,$r,$debug);
    my @errors=GP_Validate($c,$r,$mode eq 'active'?1:0,$cfg);
    my @blockers;
    if ($debug) {
        my $pending=keys %{$rt->{actors}//{}};
        for my $device (GP_DeviceNames($c)) {
            my $d=$defs{$device};
            if (($d->{ACTIONTYPE}//'') eq 'door_open') {
                $pending++ if GP_Read(GP_Attr($d->{NAME},'feedbackDevice',''),'pulse_state','') eq 'pending';
            } elsif (($d->{ACTIONTYPE}//'') eq 'garage_open') {
                $pending++ if GP_Read(GP_Attr($d->{NAME},'stateDevice',''),'state','') =~ /\A(?:movup|movdown)\z/;
            }
        }
        push @blockers,'Controller not ready' unless $rt->{ready};
        push @blockers,'Actuator operation in progress' if $pending;
        push @blockers,'Operating mode disabled' if $mode eq 'disabled';
        push @blockers,'Resident is learning; confirm setup before testing' if $mode eq 'learning';
        push @blockers,'Configuration invalid' if @errors;
    }
    return ({view=>$view,mode=>$mode,requested_mode=>GP_Mode($r),controller_mode=>GP_Mode($c->{NAME}),mode_reason=>GP_ModeReason($c,$r),
        resident=>$r,controller=>$c->{NAME},initialized=>$s?1:0,
        snapshot_at=>GP_Now()+($debug && $s?($s->{debug_offset}//0):0),
        sourceMode=>$cfg->{sourceMode},sources=>{geofency=>GP_UsesSource($cfg->{sourceMode},'geo')?1:0,
            phone=>GP_UsesSource($cfg->{sourceMode},'phone')?1:0},
        state=>$s//{},geometry=>$rt->{geometry}{$pool}{$r}//{},
        geometry_ready=>$cfg->{geometry_ready},geometry_errors=>$cfg->{geometry_errors},missing_geometry=>[GP_MissingGeometry($cfg)],
        ($debug?(debug_ready=>@blockers?0:1,debug_blockers=>\@blockers):()),
        test_webhook_isolation=>1,debug_reset_keep_geometry=>1,
        session_started_at=>$rt->{resident_start}{$r}//$rt->{start},pending_actors=>[sort keys %{$rt->{actors}//{}}],errors=>\@errors},undef,$cfg);
}

1;

=pod

=item device
=item summary Geofency and local phone presence with configurable arrival actions and isolated debugging

=begin html

<a id="GeoPresence"></a>
<h3>GeoPresence</h3>
<div>
  <p>GeoPresence updates ROOMMATE presence from Geofency webhooks, indoor phone sensors, or both. The default source profile geofency_phone combines both sources. Configurable rules request door or garage opening, send notifications, or switch on a device. A Home entry alone does not authorize opening: a confirmed departure and a valid return are required.</p>
  <h4>Device types</h4>
  <ul>
    <li><b>Controller:</b> webhook listener, shared timing and diagnostics.</li>
    <li><b>Resident:</b> one person, their phone sensors and ROOMMATE device.</li>
    <li><b>Location:</b> one Geofency zone belonging to a resident.</li>
    <li><b>Action:</b> the door, garage, notification or switch operation.</li>
    <li><b>Rule:</b> when an action applies and to which residents.</li>
  </ul>
  <p>Devices and rules are created explicitly. GeoPresence does not call the old Geo module or create configuration devices automatically.</p>
  <h4>Using FHEMWEB</h4>
  <p>Select an attribute on a device's detail page to display its English help below the input fields. Each description identifies the applicable device, accepted values, default or requirement, and an example.</p>
  <ul>
    <li>The selector shows only attributes for this device type and, for actions, this action type.</li>
    <li>Fixed values use dropdowns. Residents, locations and phone sensors use multiple selection; rules offer a dropdown for their action.</li>
    <li>Choose the value, then press <b>attr</b> to apply it. For multiple selection, click the value field, select devices and press <b>OK</b> first.</li>
    <li>Reload an open detail page after defining, deleting or renaming devices to see updated choices. With no available choices, references remain text fields.</li>
  </ul>
  <p>Public attribute references are not rewritten automatically; validation still reports missing devices. Internal parent bindings follow GeoPresence renames. Standard attributes such as <code>alias</code>, <code>room</code> and <code>verbose</code> retain FHEM's framework help.</p>
  <p>Use <code>help GeoPresence EN</code> or <code>help System.GeoPresence EN</code> for this complete English reference.</p>

  <a id="GeoPresence-define"></a>
  <h4>Define</h4>
  <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">define &lt;name&gt; GeoPresence controller
define &lt;name&gt; GeoPresence resident &lt;controller&gt; &lt;ROOMMATE&gt;
define &lt;name&gt; GeoPresence location &lt;resident&gt; &lt;function&gt;
define &lt;name&gt; GeoPresence action &lt;controller&gt; &lt;actionType&gt;
define &lt;name&gt; GeoPresence rule &lt;controller&gt;</pre>
  <p>Only one controller is supported. Parent devices and the resident's ROOMMATE must already exist. Device names start with a letter and contain only letters, digits, underscores, dots or hyphens. New residents start disabled and can be configured while other residents operate. Changes to existing devices require all affected residents to be debug or disabled. Shared configuration requires pausing all affected residents or the controller. The location function and action type are part of the definition, not attributes.</p>
  <h5>Location functions</h5>
  <ul>
    <li><code>home</code>: the inner home circle. Required once for each Geofency resident.</li>
    <li><code>outer</code>: the surrounding circle, fully containing Home. Required once for each Geofency resident; an exit can confirm a remote trip.</li>
    <li><code>place</code>: an ordinary location, such as an office, garden or checkpoint. Use freely named groups to combine locations. A sufficiently distant circle can independently confirm departure.</li>
    <li><code>approach</code>: optional surrounding arrival context and motion evidence; no opening until confirmed Home or phone arrival.</li>
  </ul>
  <p>To change an existing location's function while keeping its zoneId and readings, use <code>modify Geo.PERSON.ORT location Geo.PERSON place</code> while all affected residents are debug or disabled. Its parent cannot be changed by modify. Validate before activation.</p>
  <h5>Action types</h5>
  <ul>
    <li><code>door_open</code>: request opening through an existing door controller with feedback.</li>
    <li><code>garage_open</code>: request opening through a relay, with garage state and end contacts.</li>
    <li><code>notify</code>: send a configured message through the installed <code>pushMsg</code> function.</li>
    <li><code>switch_on</code>: send a fixed <code>on</code> command to an ordinary load such as a light.</li>
  </ul>

  <a id="GeoPresence-setup"></a>
  <h4>Setup example: PERSON and a garden light</h4>
  <p>The example assumes that <code>rr_PERSON</code>, two PRESENCE sensors and <code>test.dev.licht</code> already exist. Replace the password placeholder; the phone identifier is learned from the first authenticated test webhook. If a controller already exists, use it instead of defining a second one.</p>
  <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">define System.GeoPresence GeoPresence controller
set System.GeoPresence mode debug
attr System.GeoPresence webhookPort 8090
attr System.GeoPresence logFile ./log/geopresence-%Y-%m.log
define Geo.PERSON GeoPresence resident System.GeoPresence rr_PERSON
attr Geo.PERSON webhookUser geo_person
attr Geo.PERSON phoneProxies Phone.PERSON.RAUM1,Phone.PERSON.RAUM2
attr Geo.PERSON phoneSignalMode state
set Geo.PERSON webhookPassword __RANDOM_PASSWORD__
set Geo.PERSON mode learning</pre>
  <p>Configure Geofency to POST to your HTTPS proxy URL ending in <code>/fhem/geopresence</code>, using the configured account and password. Use Geofency's entry or exit test buttons for Home, the outer home circle, and the garden; they send <code>isTest=true</code>. These one-shot tests do not create a visit or timeline entry and are not retried automatically. Keep this same URL for normal operation. Device identifier, geometry and zone IDs come from Geofency; do not enter them manually. Inspect the candidate, then confirm it with learnConfirm:</p>
  <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence learnedLocations Geo.PERSON
set Geo.PERSON learnConfirm
get System.GeoPresence learnedLocations Geo.PERSON
get System.GeoPresence locationCommands Geo.PERSON @1 home Geo.PERSON.Home
get System.GeoPresence locationCommands Geo.PERSON @2 outer Geo.PERSON.Outer
get System.GeoPresence locationCommands Geo.PERSON @3 place Geo.PERSON.Garden</pre>
  <p>Use the actual learning numbers or UUIDs from the returned list. Execute each returned define/attr pair yourself; locationCommands only displays text. Once the locations exist, connect the light to garden entry:</p>
  <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">define Geo.Action.GardenLight GeoPresence action System.GeoPresence switch_on
attr Geo.Action.GardenLight target test.dev.licht
attr Geo.Action.GardenLight command on
define Geo.Rule.PERSONGarden GeoPresence rule System.GeoPresence
attr Geo.Rule.PERSONGarden residents Geo.PERSON
attr Geo.Rule.PERSONGarden trigger enter
attr Geo.Rule.PERSONGarden locations Geo.PERSON.Garden
attr Geo.Rule.PERSONGarden action Geo.Action.GardenLight
get System.GeoPresence validate
get System.GeoPresence logStatus
set System.GeoPresence applyGeometry Geo.PERSON
set Geo.PERSON mode debug</pre>
  <p>Test in debug before activation. New or changed geometry cancels the previous trip, pending actions and phone absence qualification; no rules execute in that event batch. A fresh, consistent Home exit may start a new unconfirmed local trip after geometry validation. It needs new departure confirmation: a full new phone absence window after the exit or independent Geo distance evidence under the source profile's normal rules. A changed-geometry Home entry alone never grants opening permission. Diagnostics identify the location, original event time and changed values in <code>geometry_changes</code>.</p>
  <p>A duplicate Home or approach entry may fill missing motion while that arrival section is still current. The current approach entry is linked to the pending arrival when Home is accepted, including when both share the same observation time. Accepted entries remain linked even after newer Home entries without motion have advanced the position. A fresh delayed Home, approach or outer exit with unchanged geometry interrupts the approach even before Home is pending. A newer nearby place observation cannot hide that interruption. Motion from before the interruption cannot qualify the garage; a later valid Home entry retains its original receipt and wait even if the exit arrives after Home. A pre-Home exit preserves an unaffected latched Home walking veto even after motion_max_age expires. If older motion is revoked, surviving evidence keeps its original evaluation time; new motion is evaluated at the current time. A valid late walking supplement still vetoes the garage, including before phone confirmation. It does not replay visits or rules, replace newer known motion, rewind the latest Home evidence, refresh original timestamps or restart the Home wait. The original Home entry still qualifies minimum absence and anchors the wait. Completed or interrupted arrivals are not reopened. Debug plans appear as <code>would execute; debug suppressed</code>. The light, door, garage, notifications and ROOMMATE are not changed by the simulation. Start with the German handbook <code>doc/GeoPresence_Handbuch.md</code> for a complete resident setup and examples of locations, actions and rules. The separate <code>doc/GeoPresence_Testanleitung.md</code> describes automated everyday tests and guided phone tests for custom actions and groups.</p>
  <p>Every output is checked immediately before the adapter call against the current mode, configuration, revocations and clocks. Manual ROOMMATE home also cancels plans already taken from the pending list: a door callback cannot leave the following garage command authorized. Slow callbacks do not extend the remaining time of later commands. The monotonic deadline is anchored to the original receipt, including time spent queued or awaiting arrival confirmation, so a backward wall-clock correction cannot extend it. Display aliases do not revoke pending commands, including alias deletion patterns such as <code>^alias$</code>. Deleting obsolete attributes also refreshes validation when a deletion pattern is used. Configuration guards apply to attribute deletion patterns and deletion of all attributes; controller changes affect every resident. Already issued actuator requests continue to receive feedback after a revocation.</p>

  <a id="GeoPresence-operation"></a>
  <h4>Operation, transport and persistence</h4>
  <h5>Operating modes</h5>
  <p>Controller and residents default to <code>disabled</code>. Set their modes explicitly. Both must be active for productive actions. Either disabled blocks processing; resident learning captures setup data under an active or debug controller; otherwise either debug selects simulation.</p>
  <p>A POST with <code>isTest=true</code> selects learning while that resident is learning, otherwise simulation even with both devices active. There is one webhook URL for learning, tests and normal operation; child paths return 404. The case-sensitive form field <code>isTest</code> accepts true/1 for tests and false/0 for normal observations; an omitted field also means normal observation. Other values or duplicate fields are rejected. Disabled devices still reject test requests. The test marker applies to that request; real webhooks and phone observations continue according to the configured modes.</p>
  <p>Debug processing uses separate state, does not publish readings or FHEM events, and never calls the output adapters. Existing hardware operations already dispatched in production are still observed until completion. The separate operator command applyGeometry explicitly confirms reviewed location metadata in ordinary readings without promoting any simulated visit or permission.</p>
  <h5>Webhook access</h5>
  <p>Use an HTTPS reverse proxy for the dedicated HTTP listener. Forward only the exact path <code>/fhem/&lt;webhookPath&gt;</code> to webhookPort. Block all child paths with HTTP 404 so that child paths cannot fall through to a general FHEMWEB proxy. This listener is not FHEMWEB and provides no FHEM command endpoint. A proxy on another machine requires an explicit webhookBindAddress and webhookAllowedPeers.</p>
  <p>Webhooks require HTTP Basic authentication and <code>application/x-www-form-urlencoded</code> POST data containing Geofency's <code>device</code>, <code>id</code>, <code>entry</code> (0/1), <code>date</code>, <code>latitude</code>, <code>longitude</code> and <code>radius</code>. Optional motion selects the Home confirmation wait and can refine the garage decision. Unused metadata may contain line breaks and tabs; decision fields remain strict. Credentials and raw payloads are not logged.</p>
  <p>After successful authentication, each resident has a separate limit of 120 requests per fixed 60-second window, starting with that resident's first authenticated request. Further authenticated requests return HTTP 429 until the window expires; failed authentication returns HTTP 401 without consuming this quota. Authenticated requests still count if later rejected for their content or operating mode. Production, debug and learning share the resident's quota, and mode changes do not renew it. The window uses monotonic elapsed time, so wall-clock corrections cannot extend it or renew it early. Connection, size and queue bounds remain separate; an HTTPS proxy can additionally limit outside traffic.</p>
  <h5>Indoor phone presence</h5>
  <p>Indoor sensors are used only by geofency_phone and phone_only. In geofency_only, phone state and health are explicitly disabled; no sensors are polled, no phone simulation is accepted, and a lost Home webhook has no phone fallback.</p>
  <p>One detecting indoor sensor is enough for presence. Changing rooms or being seen by multiple sensors does not create another arrival. Absence requires all configured sensors to be negative for phone_absence_window. A short reception gap preserves presence and cannot authorize a new opening. Phone arrival can replace a missing Home webhook after a qualified trip. A local walk can authorize the door; the garage additionally needs driving evidence or a remote trip without fresh contradictory walking/running/cycling evidence.</p>
  <p>In state mode, valid negatives observed before Home exit may start a new full absence window after the exit without another identical sensor message. Earlier elapsed time and pre-start snapshots alone cannot authorize that departure. Measurement mode still needs new, renewed measurements after the exit. A return observed or received before the full window completes cannot become eligible through later processing. A valid return after the actual deadline remains eligible even if the next poll confirms the elapsed window later.</p>
  <p>Valid phone presence can revoke an old trip and pending outputs even after its action freshness budget expires. For an active trip, the first newly accepted positive observation at or after the relevant departure anchors a phone return, including its freshness, minimum absence and output budget. A later positive reading from another sensor cannot make a delayed return fresh or extend these limits. Without an active trip, the latest valid positive observation supplies presence status, including phone_only and later status cycles after a completed trip. An older simultaneous reading cannot hide current presence behind a newer nearby location. The completed trip remains available for revocation and pending output checks; its departure times and output budgets are not renewed. This status update creates no trip permission. The trip checks also cover pre-start presence delivered only after an older trip was restored, including independently qualified Geo trips; it cannot execute a historical arrival or rewind a newer position. Observations before a genuinely later new trip do not anchor that new return. A positive observation before an absence completion invalidates that collected record, while an actual later return preserves a valid earlier completion. Polling never refreshes source timestamps.</p>
  <p>A nearby ordinary location does not interrupt valid held absence continuity. A phone-qualified trip retains its actual absolute and monotonic completion bounds for later returns, including measurement renewal after the nominal window. Only the first required renewal of each source contributes to those bounds; further identical measurements do not move an already satisfied deadline or supersede an eligible return before the next poll. The same early return is rejected in shared and separate batches. Independently qualified Geo trips and phone_only status changes retain their own contracts.</p>
  <h5>Home arrival confirmation</h5>
  <p>If held indoor presence rejects an outer departure, an earlier unarmed local Home exit remains pending when it is newer than the last actual positive phone observation. Only complete phone absence qualification can authorize that trip; rejected distance or prior-exit evidence is not retained. A new Home entry or positive phone observation cancels the unarmed suspicion. Short reception gaps therefore cannot open either actor.</p>
  <p>A qualified Home entry is provisional (<code>returning</code>). Default confirmation waits:</p>
  <ul>
    <li><b>Walking or unknown:</b> 60 seconds.</li>
    <li><b>Running:</b> 30 seconds.</li>
    <li><b>Cycling:</b> 20 seconds.</li>
    <li><b>Automotive:</b> 10 seconds.</li>
  </ul>
  <p>The faster waits need motion observations at most 30 seconds old in the current arrival section. A new local phone arrival may confirm earlier.</p>
  <p>A received newer exit cancels the provisional return without consuming its trip; queued observations are evaluated before timer confirmation. The confirmed arrival creates at most one door request per trip, even if the phone is detected later.</p>
  <p>Missing or delayed exits cannot be excluded by a timer alone. The short car wait deliberately does not reject every 15-second false entry. A fresh walking veto cannot expire into garage permission during the intentional wait.</p>
  <h5>Activation and configuration changes</h5>
  <p>Production activation validates configuration and checks for conflicting legacy arrival paths. Set the ROOMMATE's rr_locationUnderway to underway, remove old rr_geofenceUUIDs and disable the old arrival handlers before activation. Resident and private-location configuration requires that resident to be effectively debug or disabled; shared changes require pausing all affected residents. Controller configuration requires controller debug or disabled. Changes revoke the affected journeys. Diagnostic settings debugLog, logFile and standard verbose can be changed during production without resetting trips or learning.</p>
  <h5>Persistence</h5>
  <p>FHEM rename updates GeoPresence's internal controller and parent bindings, including saved definitions. A controller rename closes its old HTTP clients and rebinds the listener under the new owner. A resident rename moves its stored password verifier and retains its request quota. Affected trips and pending commands are revoked; already dispatched actuator feedback remains observed. Public rule and external-device attribute references require explicit correction after validation. Use save after correcting the configuration. If credential migration fails, gp_auth_error keeps authentication blocked across reloads; repair the key store and set webhookPassword again. Affected Geo residents are disabled.</p>
  <p>Use FHEM's normal save mechanism for definitions, attributes and production readings. A deviceId confirmed with learnConfirm is an ordinary configuration attribute; learnConfirm does not call save. Production geometry is stored in gp_geometry. A qualified unfinished production trip is stored as one versioned gp_trip_checkpoint reading. Version 2 stores current consumption and cooldowns instead of old visit histories; valid version 1 data is imported once without replaying actions or renewing departure evidence. After restart, rereadcfg or module reload it can resume if identity, configuration, geometry and the trip_resume_max_age limit still match and no later Home or indoor presence contradicts it. A NEW return is required; startup alone never opens, and old arrival timers, queued commands, unconfirmed departures and debug trips never resume. The checkpoint is consumed before dispatching opening commands. gp_resume_status/gp_resume_reason and explain describe restoration or rejection.</p>
  <p>A restored trip keeps its saved ID. Each new runtime context adds a fresh random session component; new trip IDs use that context and a local counter, so restarting the counters alone cannot recreate an old ID. This also applies to new debug contexts. Existing version 1 and 2 checkpoints remain readable.</p>
  <p>Checkpoints use the ordinary FHEM state file; no additional database or automatic configuration save is used. A clean shutdown writes the state file; after an abrupt crash only the last successfully written state is available, so observations missed during downtime cannot be reconstructed. Test requests never promote debug geometry or permissions. Learning results for a configured phone remain available in the current process after learnConfirm or timeout; a restart, new learning session, phone identity change or resident deletion discards them. An unconfirmed phone candidate is also discarded by cancellation, relevant configuration/password changes or module reload.</p>

  <p>Productive resident readings <code>gp_arrival_pending</code>, <code>gp_arrival_motion</code>, <code>gp_arrival_wait</code> and <code>gp_arrival_deadline</code> show the provisional return (deadline in Unix seconds). Debug exposes the same information under <code>state.arrival</code> in <code>get System.GeoPresence explain Geo.PERSON debug format=json</code>. English diagnostics include <code>arrival pending</code>, <code>arrival cancelled</code> and <code>arrival confirmed</code>, with motion, wait and confirmation source. These details are written only to the separate diagnostic file.</p>
  <p><code>departure rejected; pending Home exit retained</code> distinguishes a retained unarmed Home exit from a rejected outer departure and includes phone state, health and the last positive observation time. The <code>departure_armed</code> field on <code>phone absence qualified</code> distinguishes a qualified trip (1) from status-only absence (0).</p>

  <a id="GeoPresence-set"></a>
  <h4>Set commands</h4>
  <p>Use set mode directly on a controller or resident. Learning and learnConfirm belong to the resident. Debug tools and applyGeometry belong to the controller and require an explicit resident argument. Learning needs controller active or debug; simulation tools are unavailable during learning. applyGeometry accepts effective debug or a disabled resident with confirmed learning data.</p>
  <p><b>FHEMWEB:</b> Open the controller detail page, choose an individual command in the set dropdown, then select its resident or resident/value combination and press <b>set</b>. Choices include residents with the relevant source profile. An empty selection executes nothing and returns usage instructions. For debugAdvance, enter the resident and seconds separated by a space, for example <code>Geo.PERSON 180</code>. The webhookPassword command is on the resident detail page instead. Complete commands can also be entered in the FHEMWEB command line or Telnet.</p>
  <ul>
    <li><a id="GeoPresence-set-webhookPassword"></a><b>webhookPassword &lt;password&gt;</b>
      <p><b>Applies to:</b> Resident only</p>
      <p>Store a salted password verifier in FHEM's key store. Use a random 24&ndash;128 character password containing only A&ndash;Z, a&ndash;z, 0&ndash;9, underscore or hyphen, and enter it in Geofency's HTTP Basic account settings.</p>
      <p>The affected resident must not be effectively active. Changing the password revokes only this resident's trips and captured learning data; other residents continue.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set Geo.PERSON webhookPassword &lt;new-random-password&gt;</pre>
    </li>
    <li><a id="GeoPresence-set-mode"></a><b>mode active|debug|disabled|learning</b>
      <p><b>Applies to:</b> Controller and resident. Both start disabled. Select mode in the device's set dropdown; it is an operating command, not an attribute. Controller choices are active, debug and disabled; Geofency residents additionally offer learning.</p>
      <ul>
        <li><b>active:</b> validate configuration and allow productive processing only when both controller and resident are active.</li>
        <li><b>debug:</b> simulate observations without productive ROOMMATE updates, device commands or messages. Controller debug overrides all active residents; an individual resident can debug while others remain active.</li>
        <li><b>disabled:</b> stop new processing. Controller disabled blocks every resident. Explicitly disabling a learning resident cancels its unconfirmed capture, including after a timeout.</li>
        <li><b>learning:</b> resident only, with controller active or debug. Open a 15-minute window for authenticated, fresh isTest=true webhooks, replacing the previous learning list. Configure the unique webhookUser and password first. No deviceId, locations or phone sensors are needed yet. Real observations are acknowledged and ignored; no phone polling, journeys or actions run for this resident.</li>
      </ul>
      <p>The first valid test pins the phone identifier if unconfigured; later tests must match it. At most 32 locations are captured. Use Geofency's entry/exit test buttons. After timeout the resident becomes disabled; data remain reviewable and can be explicitly confirmed. Learning never activates automatically. Repeating the current mode preserves state and does not extend the window; cancel before beginning a replacement window.</p>
      <p>Mode changes revoke the affected resident's journeys and queued observations. Individual changes preserve other residents and the listening socket. Controller changes affect all residents; switching between active and debug preserves open learning windows, while disabled cancels them. Already dispatched hardware remains observed. Failed activation leaves the previous mode intact.</p>
      <p>The mode reading is saved through normal FHEM state saving. Module reload retains current active/debug/disabled modes; restart or rereadcfg restores saved modes and their original timestamps after loading the configuration. Only devices without a saved mode default to disabled. effectiveMode and modeReason explain controller precedence. Learning becomes disabled and unconfirmed captures are discarded. Only a validated qualified production trip can resume; mode changes still revoke its checkpoint. Use save after setup; recovery after a crash uses the last successfully written state file. debugLog independently controls diagnostic output.</p>
      <p><b>Resident device status:</b> FHEMWEB and list show the effective mode as STATE: disabled, learning, debug or active. New residents show disabled. For example, an active resident shows debug while the controller is in debug mode. Confirmation or expiry of learning returns the display to disabled. This is the operating mode, not home/absent presence; presence belongs to the linked ROOMMATE. The display is recalculated after reload or restart and does not create events or actions.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set System.GeoPresence mode active
set Geo.PERSON mode learning
get System.GeoPresence learnedLocations Geo.PERSON</pre>
    </li>
    <li><a id="GeoPresence-set-learnConfirm"></a><b>learnConfirm</b>
      <p><b>Applies to:</b> Geofency resident only. Explicitly confirm the captured phone and locations and close reception. A new deviceId is written using FHEM's standard attribute command; an existing identifier is never replaced. The resident remains disabled, including after a timed-out window. Repeating confirmation of already confirmed data changes nothing.</p>
      <p>No location devices, trips, ROOMMATE changes, messages or actuator commands are created. Use learnedLocations, execute the definition pairs from locationCommands, then applyGeometry to confirm reviewed metadata before testing. Empty or conflicting capture is rejected; use mode disabled to cancel. Confirmation does not call save.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set Geo.PERSON learnConfirm
get System.GeoPresence learnedLocations Geo.PERSON</pre>
    </li>
    <li><a id="GeoPresence-set-applyGeometry"></a><b>applyGeometry &lt;resident&gt;</b>
      <p><b>FHEMWEB:</b> Select applyGeometry on the controller, select the resident in the adjacent dropdown and press set.</p>
      <p>Explicitly confirm the complete, reviewed debug geometry of this Geofency resident's registered locations for production. First send Geofency entry or exit test requests for missing or changed locations, wait for processing and inspect explain with debug. Every registered location needs valid geometry. After learnConfirm, matching captured geometry also supplies registered locations. A learning list alone creates no devices. Finish any learning window before applying.</p>
      <p>The resident must be effectively debug or individually disabled with confirmed learning data. The controller may remain active. Review the captured or simulated geometry first. Checks reject missing or conflicting geometry, incorrect phone/zone bindings, invalid circle nesting, synthetic debugAdvance time and any attempt to replace newer production geometry with older differing data. A failed check changes no readings.</p>
      <p>The command resets this resident's debug and productive trips and pending observations, then writes only new or changed geometry into normal gp_geometry readings. Original observation timestamps are retained. It emits no location events, userReadings/stateFormat callbacks, ROOMMATE changes, messages or actuator commands. Other residents and feedback tracking of existing actuator operations are unaffected. Unchanged production metadata is left intact.</p>
      <p>After confirmation, mode changes and reloads can load the geometry from the readings. Use FHEM's normal state saving for restart persistence; this command does not call save. New real departure and arrival evidence is still required for opening. The test application never calls this command.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence explain Geo.PERSON debug
set System.GeoPresence applyGeometry Geo.PERSON
set Geo.PERSON mode active
get System.GeoPresence validate Geo.PERSON</pre>
    </li>
    <li><a id="GeoPresence-set-debugReset"></a><b>debugReset &lt;resident&gt; [keepGeometry]</b>
      <p><b>Applies to:</b> Controller only</p>
      <p>Discard this resident's debug trip, queued debug events, simulated geometry and clock offset. Reset the debug phone mode to live. Unavailable during learning or disabled operation; use the resident mode command to cancel learning. Confirmed setup results remain available.</p>
      <p>Add <code>keepGeometry</code> to keep the currently available debug geometry, including timestamps and conflict flags, while still discarding all travel history, pending arrivals and action plans. The automatic test application uses this option before scenarios and at cleanup so another invocation can reuse the same locations. Geometry stays in memory and is not written to productive readings. Mode/configuration changes, reloads, restarts and a reset without this option can still discard it.</p>
      <p><code>keepGeometry</code> requires a real-time debug session. After debugAdvance, use a full reset without this option and synchronize geometry again; synthetic timestamps must not carry over to real-time tests.</p>
      <p>Production state and devices are unchanged.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set System.GeoPresence debugReset Geo.PERSON keepGeometry</pre>
    </li>
    <li><a id="GeoPresence-set-debugPhoneMode"></a><b>debugPhoneMode &lt;resident&gt; live|simulated</b>
      <p><b>Applies to:</b> Controller only</p>
      <p>Choose real indoor sensors or isolated simulated phone observations for this resident's debug state. Requires geofency_phone or phone_only; unavailable in geofency_only. Reset the debug phone evaluation; after selecting simulated, explicitly set the desired value with debugPhone.</p>
      <p>Real PRESENCE devices are unchanged.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set System.GeoPresence debugPhoneMode Geo.PERSON simulated</pre>
    </li>
    <li><a id="GeoPresence-set-debugPhone"></a><b>debugPhone &lt;resident&gt; present|absent</b>
      <p>Controller only; requires a phone-enabled source profile and debugPhoneMode simulated. Supply this value to all simulated phone sources on following polls. Unavailable in geofency_only.</p>
      <p>Absence still needs the configured qualification time; this does not immediately set the resident absent.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set System.GeoPresence debugPhone Geo.PERSON absent</pre>
    </li>
    <li><a id="GeoPresence-set-debugAdvance"></a><b>debugAdvance &lt;resident&gt; &lt;seconds&gt;</b>
      <p>Controller only; requires simulated phone mode or geofency_only. Advance only the debug clock by an integer from 1 to 86400 seconds.</p>
      <p>Intended for controlled synthetic tests. Do not use during phone or automated everyday tests: their webhooks carry real event times.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set System.GeoPresence debugAdvance Geo.PERSON 180</pre>
    </li>
  </ul>

  <a id="GeoPresence-get"></a>
  <h4>Get commands</h4>
  <p>These commands return information without executing device definitions or actuator commands. The examples use the controller; debugTrace and explain also infer the resident when invoked on a resident device without a resident argument.</p>
  <p><b>Output formats:</b> FHEMWEB shows formatted reports; Telnet uses uppercase section headings, underlines, aligned values and indented entries. Prose wraps at about 80 columns; identifiers and commands are never cut. Append <code>format=json</code> for scripts, <code>format=text</code> for text in either interface, or <code>format=html</code> for HTML. Browser text is displayed in a safe, wrapping text block.</p>
  <p>JSON contains complete diagnostic data and Unix timestamps; errors use an <code>error</code> field. Reports are snapshots: reading them does not confirm arrivals, create a simulation, send commands or advance timers.</p>
  <ul>
    <li><a id="GeoPresence-get-validate"></a><b>validate [&lt;resident&gt;]</b>
      <p>Validate all configured residents, including disabled ones, or one named resident. Success starts with <code>OK: configuration valid</code>; findings identify the affected device. Missing Home, outer or configured approach geometry blocks opening; missing ordinary place geometry is reported as a notice without invalidating the configuration. The automatic test application also needs geometry for those places. With <code>format=json</code>, the result contains <code>valid</code>, <code>errors</code> and <code>warnings</code>.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence validate Geo.PERSON</pre>
    </li>
    <li><a id="GeoPresence-get-learnedLocations"></a><b>learnedLocations &lt;resident&gt;</b>
      <p>Show the captured Device ID, its Binding (not configured or configured), reception status and a table of locations with learning number, name, zone ID, radius and local timestamp. While waiting for a new phone, the report explains that the first authenticated test webhook is required.</p>
      <p>Append <code>format=json</code> for the unchanged location array including coordinates; identity and reception status appear in the text/HTML report. Results for a configured phone survive learnConfirm, the reception timeout and module reloads in the same FHEM process. Unconfirmed candidates are discarded on a session reset. The location list itself is never saved as configuration.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence learnedLocations Geo.PERSON</pre>
    </li>
    <li><a id="GeoPresence-get-locationCommands"></a><b>locationCommands &lt;resident&gt; &lt;zoneId-or-@number&gt; &lt;function&gt; &lt;newDeviceName&gt;</b>
      <p>Return a define command and zoneId attribute for a captured location; execute that output yourself. For a newly learned phone, confirm its deviceId with learnConfirm first. Select a UUID or learning number and function home, outer, place or optional approach. Use groups for freely named location categories.</p>
      <p>The target device must not already exist. Telnet returns only the commands, ready to copy; FHEMWEB shows them in a wrapping command block. With <code>format=json</code>, the result contains a <code>commands</code> array.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence locationCommands Geo.PERSON @1 home Geo.PERSON.Home</pre>
    </li>
    <li><a id="GeoPresence-get-debugTrace"></a><b>debugTrace &lt;resident&gt; [limit=&lt;count&gt;]</b>
      <p>Show the newest 20 recorded debug decisions first, even when file diagnostics are disabled. Use <code>limit=100</code> to see more; accepted counts are 1 to 1000. A <code>would execute; debug suppressed</code> entry describes an action plan, not a physical action or delivery confirmation.</p>
      <p>With <code>format=json</code>, the full retained history is returned in its original chronological order, unless an explicit limit selects only the newest entries.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence debugTrace Geo.PERSON</pre>
    </li>
    <li><a id="GeoPresence-get-explain"></a><b>explain [&lt;resident&gt;] [prod|debug]</b>
      <p>Show the complete report for one resident with a prominent <b>=== DEBUG ===</b> or <b>=== PRODUCTION ===</b> banner. On the controller, a resident argument is required; on a resident device it can be omitted. Status shows Resident mode, Controller mode, Effective mode and Mode reason. These are independent of the selected report view. Selecting a report never changes that mode or processes events.</p>
      <ul>
        <li>No selector or <code>prod</code>: always inspect production, including when the resident is in debug mode. Paused processing and uninitialized states are labelled explicitly.</li>
        <li><code>debug</code>: inspect the isolated simulation, including test webhooks received while production is active.</li>
      </ul>
      <p><b>FHEMWEB:</b> Select explain and choose the resident from the dropdown, for example Geo.PERSON or Geo.PERSON debug. On a resident device, select prod or debug. All sections are included; lower sections are expandable. Telnet uses uppercase headings, underlines, aligned status values and one field per line, without inserting line breaks within a value.</p>
      <p><b>Geometry:</b> Opening checks cover Home, outer, configured approach and conflicts. Locations and geometry lists every radius and missing place. For missing geometry of a registered location, keep the resident in debug, send a fresh Geofency test and wait for processing. No new definition or mode learning is needed. Explicit applyGeometry confirms reviewed metadata before activation.</p>
      <p><b>Actions:</b> Eligibility does not mean a command was sent. Previous results and existing productive operations are labelled separately. Debug ready means simulation is available with no known ongoing actuator operation; it does not grant opening permission.</p>
      <p><b>Recent decisions:</b> Immediately below Status, initially expanded in FHEMWEB and collapsible by clicking its heading. Arrival actions starts collapsed. Rule / source identifies the rule, location, observation source or actuator target recorded for that decision. Not recorded means that the stored entry has no such information; a later observation is never substituted.</p>
      <p><b>JSON:</b> format=json returns the complete selected state. Fields include view (production or debug), mode (effective), requested_mode, controller_mode, mode_reason, initialized, state, geometry, geometry_ready, geometry_errors, missing_geometry, pending_actors and errors. The debug view also includes debug_ready and debug_blockers. Module capabilities test_webhook_isolation and debug_reset_keep_geometry remain available to the test application. To compare production and simulation, query each separately.</p>
      <p><b>Examples:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence explain Geo.PERSON
get System.GeoPresence explain Geo.PERSON debug
get System.GeoPresence explain Geo.PERSON prod
get System.GeoPresence explain Geo.PERSON debug format=json
get Geo.PERSON explain debug</pre>
    </li>
    <li><a id="GeoPresence-get-logStatus"></a><b>logStatus</b>
      <p>Show the normal log destination, diagnostic file, verbosity, diagnostic setting, separate simulation/learning/production output flags, rate limit and last write error. Enabled flags describe configured output, not verified write permissions. Append <code>format=json</code> for fields <code>debugEnabled</code>, <code>learningEnabled</code> and <code>activeEnabled</code>.</p>
      <p>Normal output goes to FHEM; detailed diagnostics go only to logFile.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence logStatus</pre>
    </li>
    <li><a id="GeoPresence-get-timerStats"></a><b>timerStats</b>
      <p>Show timer work, delayed starts and counters in separate sections, with millisecond units and a readable local start time. A Freezemon candidate is not proof of causation: GeoPresence may simply be waiting for another FHEM callback to finish. Millisecond statistics include synchronous callbacks and remain in memory until controller deletion or FHEM restart.</p>
      <p>With <code>format=json</code>, the original fields are retained: <code>runs</code>, <code>slow_runs</code>, <code>last_ms</code>, <code>mean_ms</code>, <code>max_ms</code> and per-callback device/configuration counts. <code>last_lag_ms</code>, <code>max_lag_ms</code> and <code>late_runs</code> measure delayed starts separately from the timer's own work; <code>last_started_at</code> is Unix time.</p>
      <p>Passive profiling also records the slowest measured run, its time, device and processing phases. <code>actor_command</code> includes the actuator's synchronous FHEM callbacks; <code>roommate_command</code> includes ROOMMATE callbacks; <code>resident_reading_callbacks</code> and <code>geometry_reading_callbacks</code> include notifications and userReadings caused by those updates. <code>diagnostic_file</code> measures file open/write/close; <code>normal_log</code> measures FHEM logging. No action behavior, polling interval or operating mode is changed.</p>
      <p>Phase <b>Elapsed</b> includes nested measured calls; <b>Self</b> excludes them. Do not add inclusive phase times. Process CPU time is approximate and has platform-dependent resolution. A low CPU value can accompany I/O waiting or OS scheduling delays; it does not identify the wait by itself.</p>
      <p><code>last_run</code>, <code>worst_run</code> and <code>worst_late_run</code> contain full phase breakdowns in JSON; <code>recent_slow</code> and <code>recent_late</code> retain up to twelve runs of at least 500 ms each. The readable report shows the largest six self-time totals of the slowest profiled run and the newest five entries of each history. Profiling is independent of debugLog and creates no readings or events. <code>profile_started_at</code> marks the beginning of available detail; older aggregate maxima may have no breakdown.</p>
      <p>Work of at least 500 ms produces a rate-limited <code>timer_slow</code> diagnostic in the separate diagnostic file when debugLog permits it. This names the largest measured phase and target; its own write is included in the final in-memory timerStats measurement. Use FHEM's <code>apptime max top</code> and <code>apptime maxDly top</code> to investigate other callbacks. In apptime, TS Max call is the time of the longest execution, not the largest start delay.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">get System.GeoPresence timerStats</pre>
    </li>
  </ul>

  <a id="GeoPresence-attr"></a>
  <h4>Attributes</h4>
  <p>Comma-separated lists must not contain spaces. References are FHEM device names, not aliases or Geofency display names. Unless stated otherwise, changing configuration requires all affected residents to be debug or disabled and resets only their runtime sessions. Controller-wide settings require controller debug or disabled. Shared rule/action changes include previous and proposed residents and shared physical targets. New inactive residents and their private devices can be configured while others are active. Defaults apply when an attribute is absent.</p>
  <h5>Controller: operation, listener and diagnostics</h5>
  <ul>
    <li><a id="GeoPresence-attr-webhookPath"></a><b>webhookPath</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>geopresence</code></p>
      <p>A single path component beginning with a letter, followed by letters, digits, underscores or hyphens; no slashes. Creates only /fhem/&lt;value&gt;. The isTest form field selects test processing; there is no separate test URL.</p>
      <p>Use the same exact path in Geofency and the reverse proxy.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence webhookPath geopresence</pre>
    </li>
    <li><a id="GeoPresence-attr-webhookPort"></a><b>webhookPort</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>8090</code></p>
      <p>Integer 1024&ndash;65535 for the module's own HTTP listener, separate from FHEMWEB. Omitting or deleting the attribute uses port 8090. Forward the exact webhook path from your HTTPS proxy to this port.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence webhookPort 8090</pre>
    </li>
    <li><a id="GeoPresence-attr-webhookBindAddress"></a><b>webhookBindAddress</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>127.0.0.1</code></p>
      <p>A concrete local IPv4 address; hostnames and wildcard 0.0.0.0 are rejected. Loopback works for a proxy on the same host.</p>
      <p>For the separate gateway in this installation, use the FHEM host's LAN address and explicitly configure webhookAllowedPeers.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence webhookBindAddress 192.0.2.20</pre>
    </li>
    <li><a id="GeoPresence-attr-webhookAllowedPeers"></a><b>webhookAllowedPeers</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>127.0.0.1</code><br>
      <b>Note:</b> must be explicitly set when binding outside loopback</p>
      <p>A comma-separated list of 1&ndash;16 distinct IPv4 addresses allowed to connect. Use the immediate TCP peer, usually the reverse proxy, not the iPhone or an X-Forwarded-For address.</p>
      <p>This does not replace webhook authentication.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence webhookAllowedPeers 192.0.2.10</pre>
    </li>
    <li><a id="GeoPresence-attr-logFile"></a><b>logFile</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Note:</b> No default file; without this attribute no diagnostic file is written</p>
      <p>Local filename ending in .log or .txt, at most 512 characters, using letters, digits, underscore, dot, slash, plus, hyphen and the date patterns %Y, %m, %d, %H, %M. Relative paths use FHEM's working directory; the parent directory must already exist and be writable.</p>
      <p>All diagnostic levels go exclusively here, independently of verbose, when debugLog enables them. At most 300 entries plus one suppression notice per minute; no credentials or raw payloads.</p>
      <p>File errors appear in logStatus and produce at most one short FHEM warning per minute, never a diagnostic fallback. Changing this attribute does not reset a trip or learning.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence logFile ./log/geopresence-%Y-%m.log</pre>
    </li>
    <li><a id="GeoPresence-attr-debugLog"></a><b>debugLog</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Values:</b> <code>auto</code>, <code>0</code>, <code>1</code><br>
      <b>Default:</b> <code>auto</code></p>
      <p>auto writes diagnostics for learning and debug processing, including an individual resident or a webhook marked isTest=true. 1 also writes detailed diagnostics during production; 0 disables file diagnostics. Requires logFile.</p>
      <p>This controls logging only: it does not change operating modes or permit/suppress actions. Changes do not reset trips or learning.</p>
      <p>Normal English action messages remain in FHEM's log, controlled by verbose (3 for actions, 2 for operational errors, 1 for file warnings).</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence debugLog 1</pre>
    </li>
  </ul>
  <h5>Controller: timing and distance</h5>
  <p>These controller settings apply to all its residents. Values must be positive; decimals are accepted. Arrival confirmation settings are limited to 300 seconds, other values to 172800. Values are seconds except departure_margin, which is metres.</p>
  <ul>
    <li><a id="GeoPresence-attr-action_max_age"></a><b>action_max_age</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>90</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Maximum age of an observation for current decisions and action dispatch. Delayed retries cannot perform an old opening.</p>
      <p>This limits observations, not the lifetime of an otherwise valid remote trip. It must be greater than reorder_window.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence action_max_age 90</pre>
    </li>
    <li><a id="GeoPresence-attr-future_tolerance"></a><b>future_tolerance</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>30</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Allowed event-time lead over the server clock and tolerance for clock discontinuities. Also defines the start boundary before new Geo evidence can qualify after session reset; old observations must not reactivate a saved trip.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence future_tolerance 30</pre>
    </li>
    <li><a id="GeoPresence-attr-reorder_window"></a><b>reorder_window</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>2</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>The first receipt fixes the collection deadline for this resident and production/debug context. At the first timer run after that deadline, all observations already received in that context are evaluated together in event-time order; later arrivals do not extend the window. Newer counterevidence in the batch is processed before arrival confirmation. Conflict comparisons are limited to equal observation times. Larger values increase response latency. The value must be smaller than action_max_age, including when an attribute is deleted and its default applies. Interactive edits check the proposed pair; startup and rereadcfg check the relationship only after all saved attributes have been loaded.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence reorder_window 2</pre>
    </li>
    <li><a id="GeoPresence-attr-departure_grace"></a><b>departure_grace</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>60</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Delay after Home exit before absence can be displayed if the phone is not still considered present. This timer alone never grants return-opening permission.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence departure_grace 60</pre>
    </li>
    <li><a id="GeoPresence-attr-minimum_away"></a><b>minimum_away</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>60</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Minimum elapsed absence before a qualified return can open. Both event times and elapsed runtime must satisfy it; a quick boundary bounce does not authorize opening.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence minimum_away 60</pre>
    </li>
    <li><a id="GeoPresence-attr-phone_absence_window"></a><b>phone_absence_window</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>180</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Require every configured phone sensor to remain negative for this interval. Also retain presence as present/handover during a shorter reception gap; a room change must not create a new opening permission.</p>
      <p>Sensor errors interrupt qualification.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence phone_absence_window 180</pre>
    </li>
    <li><a id="GeoPresence-attr-phone_poll"></a><b>phone_poll</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>5</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Interval between evaluations of the existing phone sensor readings. Polling does not start a sensor scan or create a new real measurement.</p>
      <p>Processing occurs on the module's timer.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence phone_poll 5</pre>
    </li>
    <li><a id="GeoPresence-attr-motion_max_age"></a><b>motion_max_age</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>180</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Validity of usable motion evidence within the arrival context. Automotive evidence can qualify the garage; fresh walking, running or cycling without current automotive evidence suppresses it.</p>
      <p>Missing motion does not erase a still-fresh useful observation.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence motion_max_age 180</pre>
    </li>
    <li><a id="GeoPresence-attr-arrival_wait_walking"></a><b>arrival_wait_walking</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>60</code> seconds<br>
      <b>Range:</b> greater than 0 through 300</p>
      <p>Home return confirmation wait measured from receipt of the first accepted entry, after an already qualified departure. Walking evidence may be retained for motion_max_age; missing motion does not erase it.</p>
      <p>A newer exit cancels the wait; a new local phone arrival can finish it early. Repeated entries do not restart it.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence arrival_wait_walking 60</pre>
    </li>
    <li><a id="GeoPresence-attr-arrival_wait_running"></a><b>arrival_wait_running</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>30</code> seconds<br>
      <b>Range:</b> greater than 0 through 300</p>
      <p>Home return confirmation wait measured from receipt of the first accepted entry, after an already qualified departure. Requires running evidence no older than arrival_motion_max_age.</p>
      <p>A newer exit cancels the wait; a new local phone arrival can finish it early. Repeated entries do not restart it.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence arrival_wait_running 30</pre>
    </li>
    <li><a id="GeoPresence-attr-arrival_wait_cycling"></a><b>arrival_wait_cycling</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>20</code> seconds<br>
      <b>Range:</b> greater than 0 through 300</p>
      <p>Home return confirmation wait measured from receipt of the first accepted entry, after an already qualified departure. Requires cycling evidence no older than arrival_motion_max_age.</p>
      <p>A short wait does not itself grant garage permission. A newer exit cancels the wait; a new local phone arrival can finish it early.</p>
      <p>Repeated entries do not restart it.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence arrival_wait_cycling 20</pre>
    </li>
    <li><a id="GeoPresence-attr-arrival_wait_automotive"></a><b>arrival_wait_automotive</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>10</code> seconds<br>
      <b>Range:</b> greater than 0 through 300</p>
      <p>Home return confirmation wait measured from receipt of the first accepted entry, after an already qualified departure. Requires automotive evidence no older than arrival_motion_max_age.</p>
      <p>This is a comfort compromise: a false entry lasting longer than the wait can still open. A newer exit cancels the wait; a new local phone arrival can finish it early.</p>
      <p>Repeated entries do not restart it.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence arrival_wait_automotive 10</pre>
    </li>
    <li><a id="GeoPresence-attr-arrival_wait_unknown"></a><b>arrival_wait_unknown</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>60</code> seconds<br>
      <b>Range:</b> greater than 0 through 300</p>
      <p>Home return confirmation wait measured from receipt of the first accepted entry, after an already qualified departure. Used without usable motion evidence, including stationary alone or expired fast-motion evidence.</p>
      <p>A newer exit cancels the wait; a new local phone arrival can finish it early. Repeated entries do not restart it.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence arrival_wait_unknown 60</pre>
    </li>
    <li><a id="GeoPresence-attr-arrival_motion_max_age"></a><b>arrival_motion_max_age</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>30</code> seconds<br>
      <b>Range:</b> greater than 0 through 300</p>
      <p>Maximum age of running, cycling or automotive observations when selecting a faster Home confirmation wait. Only evidence from the current arrival section qualifies.</p>
      <p>This is independent of motion_max_age for garage decisions; it is the webhook observation age, not an independently measured activity confidence.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence arrival_motion_max_age 30</pre>
    </li>
    <li><a id="GeoPresence-attr-approach_timeout"></a><b>approach_timeout</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>600</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Lifetime of the optional approach context. Has no effect without an approach location; an approach location is not needed for the standard setup and cannot request opening.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence approach_timeout 600</pre>
    </li>
    <li><a id="GeoPresence-attr-zone_display_max_age"></a><b>zone_display_max_age</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>43200</code> seconds (12 hours)<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Expire old zone observations for display. Explicit group membership and prior-exit evidence do not arise from display expiry; a missing exit stays missing. This does not end a confirmed remote trip or trigger an opening.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence zone_display_max_age 43200</pre>
    </li>
    <li><a id="GeoPresence-attr-actor_timeout"></a><b>actor_timeout</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>60</code> seconds<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Wait for completion feedback after a productive door/garage command. Missing confirmation produces uncertain and releases the reservation; it does not automatically resend an opening pulse.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence actor_timeout 60</pre>
    </li>
    <li><a id="GeoPresence-attr-trip_resume_max_age"></a><b>trip_resume_max_age</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>172800</code> seconds (48 hours)<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Maximum age of the original confirmed departure when restoring a qualified trip after restart, rereadcfg or module reload. Checkpoints retain the original evidence time; saving or restarting does not renew it. The limit applies to recovery, not to uninterrupted trips in one running process. Expired or changed checkpoints are rejected without actions.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence trip_resume_max_age 172800</pre>
    </li>
    <li><a id="GeoPresence-attr-departure_margin"></a><b>departure_margin</b>
      <p><b>Applies to:</b> Controller<br>
      <b>Default:</b> <code>200</code> metres<br>
      <b>Range:</b> greater than 0 through 172800</p>
      <p>Required clearance between Home and the edge of a distant location's circle for that location to prove departure. This is a distance threshold, not a second copy of a Geofency radius or a new zone to create.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr System.GeoPresence departure_margin 200</pre>
    </li>
  </ul>
  <h5>Resident</h5>
  <ul>
    <li><a id="GeoPresence-attr-sourceMode"></a><b>sourceMode</b>
      <p><b>Applies to:</b> Resident<br>
      <b>Values:</b> <code>geofency_phone</code>, <code>geofency_only</code>, <code>phone_only</code><br>
      <b>Default:</b> <code>geofency_phone</code></p>
      <ul>
        <li><code>geofency_phone</code>: authenticated Geo evidence plus indoor sensors, local contradiction checks and phone fallback. Requires Home/outer locations and phoneProxies. This remains the default for existing installations.</li>
        <li><code>geofency_only</code>: authenticated Geo evidence without indoor sensors. Requires Home/outer locations. Opening additionally needs a distant Geo observation, such as an outer exit or a sufficiently distant checkpoint; Home exit, motion and elapsed time alone do not qualify. There is no phone fallback or early phone confirmation.</li>
        <li><code>phone_only</code>: presence from indoor sensors. Requires phoneProxies, no Geo identity, password or locations. No Geo webhooks, learning or automatic opening.</li>
      </ul>
      <p>FHEMWEB offers the attributes relevant to the selected profile. Phone-only residents have no Geo credential or opening-permission controls. Stored inactive settings are not evaluated; validate lists them for explicit deletion. Changing the profile requires this resident to be effectively debug or disabled and resets trips, pending arrivals and learning reception.</p>
      <p>For geofency_only, a distant circle must be more than departure_margin away from the Home boundary. An enclosing circle proves distance on exit only if even its nearest boundary has this clearance. Identical Home/outer boundaries do not qualify. Normal minimum-away and motion-dependent return waits still apply; common GPS errors cannot be ruled out by Geo evidence alone.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON sourceMode geofency_phone</pre>
    </li>
    <li><a id="GeoPresence-attr-deviceId"></a><b>deviceId</b>
      <p><b>Applies to:</b> Resident<br>
      <b>Requirement:</b> Required for normal geofency_phone and geofency_only operation; leave unset when enrolling a new phone</p>
      <p>The Geofency phone identifier in the webhook's device field, not an FHEM name or zone UUID. Must be unique among residents.</p>
      <p>Use mode learning, send a test webhook and confirm with learnConfirm to set this attribute automatically. You do not need to find or copy the identifier in the app. An existing value is never overwritten by learning. Use FHEM save after setup to persist the confirmed attribute.</p>
      <p>Identifiers contain 1&ndash;128 ASCII letters/digits/underscores/dots/hyphens, starting with a letter or digit; comparison is case-insensitive. Changing the identity discards its learning results.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">set Geo.PERSON mode learning</pre>
    </li>
    <li><a id="GeoPresence-attr-webhookUser"></a><b>webhookUser</b>
      <p><b>Applies to:</b> Resident<br>
      <b>Requirement:</b> Required for geofency_phone and geofency_only; no default</p>
      <p>Unique HTTP Basic username; enter exactly the same spelling in Geofency. Use 1&ndash;128 ASCII letters/digits/underscores/dots/hyphens, starting with a letter or digit.</p>
      <p>Configure its password with set webhookPassword, not an attribute.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON webhookUser geo_person</pre>
    </li>
    <li><a id="GeoPresence-attr-phoneProxies"></a><b>phoneProxies</b>
      <p><b>Applies to:</b> Resident<br>
      <b>Requirement:</b> Required for geofency_phone and phone_only: a non-empty, comma-separated list of distinct existing PRESENCE devices; no default. Unused in geofency_only.</p>
      <p>Use the multiple-selection dialog to choose existing devices. List all indoor sensors for this phone, without spaces. These are the phone sources evaluated by GeoPresence; no separate aggregation device is required.</p>
      <p>Any positive sensor means presence; absence requires every listed sensor to be negative throughout phone_absence_window. Simultaneous detection and handover between rooms count as continuous presence.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON phoneProxies Phone.PERSON.RAUM1,Phone.PERSON.RAUM2</pre>
    </li>
    <li><a id="GeoPresence-attr-phoneSignalMode"></a><b>phoneSignalMode</b>
      <p><b>Applies to:</b> Resident with geofency_phone or phone_only; unused in geofency_only<br>
      <b>Values:</b> <code>state</code>, <code>measurement</code><br>
      <b>Default:</b> <code>state</code></p>
      <ul>
        <li><code>state</code>: retain each sensor value until a change or detected error. Use this for sensors that report only changes.</li>
        <li><code>measurement</code>: require repeated fresh measurements from every sensor. Freshness is twice the longer sensor interval plus 30 seconds.</li>
      </ul>
      <p>After Home exit, state mode may use still-valid negatives from before the exit for a new complete absence window. Time before the exit does not count. Measurement mode requires new observations after the exit and renewed measurements during qualification. Pre-start snapshots alone cannot authorize a new trip.</p>
      <p>An explicit failure interrupts absence qualification; recovery alone does not restore invalidated old observations.</p>
      <p>A silent unreported sensor failure cannot be detected reliably from held state alone.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON phoneSignalMode state</pre>
    </li>
    <li><a id="GeoPresence-attr-allowDoor"></a><b>allowDoor</b>
      <p><b>Applies to:</b> Resident with geofency_phone or geofency_only<br>
      <b>Values:</b> <code>0</code>, <code>1</code><br>
      <b>Default:</b> <code>0</code></p>
      <p>Permit door-opening plans for this person. Requires a matching door rule and a qualified return; setting 1 alone neither opens nor bypasses departure checks.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON allowDoor 1</pre>
    </li>
    <li><a id="GeoPresence-attr-allowGarage"></a><b>allowGarage</b>
      <p><b>Applies to:</b> Resident with geofency_phone or geofency_only<br>
      <b>Values:</b> <code>0</code>, <code>1</code><br>
      <b>Default:</b> <code>0</code></p>
      <p>Permit garage-opening plans for this person, in addition to a matching rule and garage eligibility. Keep 0 for a person who should receive only door opening, even if a shared rule accidentally includes them.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON allowGarage 0</pre>
    </li>
  </ul>
  <h5>Location</h5>
  <ul>
    <li><a id="GeoPresence-attr-zoneId"></a><b>zoneId</b>
      <p><b>Applies to:</b> Location<br>
      <b>Requirement:</b> Required; no default</p>
      <p>The location identifier from Geofency's id field, usually a UUID, unique within this resident. Obtain it with learnedLocations/locationCommands; do not use the display name, radius, phone ID or learning number as this value.</p>
      <p>Use 1&ndash;128 ASCII letters/digits/underscores/dots/hyphens, starting with a letter or digit; comparison is case-insensitive. Geometry comes automatically from authenticated webhooks.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON.Home zoneId 01234567-89ab-cdef-0123-456789abcdef</pre>
    </li>
    <li><a id="GeoPresence-attr-label"></a><b>label</b>
      <p><b>Applies to:</b> Location<br>
      <b>Default:</b> the device name for place, otherwise the function name</p>
      <p>Human-readable location name used in GeoPresence state and logs; does not change the zone ID, function, groups or rule matching. Use a single-line text without semicolons.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON.Garden label Front garden</pre>
    </li>
    <li><a id="GeoPresence-attr-groups"></a><b>groups</b>
      <p><b>Applies to:</b> Location<br><b>Default:</b> unset<br><b>Values:</b> 1..16 distinct case-sensitive group names separated by commas without spaces</p>
      <p>Assign freely named tags such as Offices or Sport. Each name starts with a letter and contains at most 64 letters, digits, dots, underscores or hyphens. Groups are resident-local; the same tag on several residents supports shared rules without merging their presence. This attribute does not change the location's system function or geometric departure evidence.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.PERSON.ORT groups Offices</pre>
    </li>
  </ul>
  <h5>Action</h5>
  <ul>
    <li><a id="GeoPresence-attr-target"></a><b>target</b>
      <p><b>Applies to:</b> Action of type door_open, garage_open or switch_on<br>
      <b>Requirement:</b> Required existing FHEM device name; no default</p>
      <p>Receives the fixed command configured below. Conflicting switch/door/garage definitions for the same target are rejected. notify uses pushMsg and needs no target.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.GardenLight target test.dev.licht</pre>
    </li>
    <li><a id="GeoPresence-attr-command"></a><b>command</b>
      <p><b>Applies to:</b> Action<br>
      <b>Values:</b> <code>lock unlocked</code> for door_open; <code>on</code> for garage_open and switch_on<br>
      <b>Default:</b> None; required for these action types</p>
      <p>Only these fixed commands are supported. Do not include set, the target device, a command chain or a Perl expression. notify needs no command.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.GardenLight command on</pre>
    </li>
    <li><a id="GeoPresence-attr-contact"></a><b>contact</b>
      <p><b>Applies to:</b> door_open action<br>
      <b>Requirement:</b> Required existing door contact device; no default</p>
      <p>Its state reading must report closed or open. With the default positionSignalMode=state, an unchanged saved contact remains valid until a change or reported fault. Measurement mode requires a post-session reading. A closed door can receive an opening request; an open or unknown door does not receive another pulse.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Door contact Door.Contact</pre>
    </li>
    <li><a id="GeoPresence-attr-feedbackDevice"></a><b>feedbackDevice</b>
      <p><b>Applies to:</b> door_open action<br>
      <b>Requirement:</b> Required existing device exposing the door controller's pulse_state reading; no default</p>
      <p>pending means a pulse is running; a new confirmed, failed or cancelled event completes its reservation. A later idle does not erase that completion.</p>
      <p>Confirmation proves the pulse, not physical opening.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Door feedbackDevice Door.Controller</pre>
    </li>
    <li><a id="GeoPresence-attr-stateDevice"></a><b>stateDevice</b>
      <p><b>Applies to:</b> garage_open action<br>
      <b>Requirement:</b> Required existing garage state device; no default</p>
      <p>Its state reading uses off (closed), on (open), movup (opening) and movdown (closing). Opening also requires consistent upper/lower contacts under the selected positionSignalMode.</p>
      <p>Unknown, inconsistent or closing states do not receive a new impulse.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Garage stateDevice Garage.State</pre>
    </li>
    <li><a id="GeoPresence-attr-upperContact"></a><b>upperContact</b>
      <p><b>Applies to:</b> garage_open action<br>
      <b>Requirement:</b> Required existing upper end-contact device; no default</p>
      <p>state must be closed at the fully open end position and open otherwise. With garage state off, this contact must be open and lowerContact closed to authorize an opening pulse.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Garage upperContact Garage.Upper</pre>
    </li>
    <li><a id="GeoPresence-attr-lowerContact"></a><b>lowerContact</b>
      <p><b>Applies to:</b> garage_open action<br>
      <b>Requirement:</b> Required existing lower end-contact device; no default</p>
      <p>state must be closed at the fully closed end position and open otherwise. Both contacts closed is inconsistent; both open is a moving/intermediate position and does not qualify as closed.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Garage lowerContact Garage.Lower</pre>
    </li>
    <li><a id="GeoPresence-attr-positionSignalMode"></a><b>positionSignalMode</b>
      <p><b>Applies to:</b> door_open and garage_open actions<br>
      <b>Values:</b> <code>state</code>, <code>measurement</code><br>
      <b>Default:</b> <code>state</code></p>
      <p>state uses latched contact/position readings: a value remains valid across restart until changed or a detectable device/IO fault occurs. The sources must report transitions and reconcile their physical state after outages. Unknown values, future timestamps, disabled sources, reported disconnection and inconsistent garage contacts block commands. An unreported sensor outage cannot be detected from an unchanged reading alone.</p>
      <p>measurement requires every position source to have reported after the controller session began. Use it when your source guarantees repeated measurements or startup refreshes. Completion feedback after a command always needs a new update/event belonging to that request, independently of this option.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Door positionSignalMode state</pre>
    </li>
    <li><a id="GeoPresence-attr-message"></a><b>message</b>
      <p><b>Applies to:</b> notify action<br>
      <b>Requirement:</b> Required non-empty configured text, at most 500 characters both before and after substitution; no default</p>
      <p><code>%resident%</code> expands to the ROOMMATE alias or device name. Control characters, semicolons, braces and backslashes are forbidden.</p>
      <p>No free-form webhook text is executed. Production logs include the configured message; debug records only its planned rule/action.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Work message %resident% arrived at work.</pre>
    </li>
    <li><a id="GeoPresence-attr-priority"></a><b>priority</b>
      <p><b>Applies to:</b> notify action<br>
      <b>Values:</b> <code>0</code> (default, information), <code>1</code> (warning), <code>2</code> (error)</p>
      <p>Passed to the installed pushMsg function; that function determines delivery and speech behaviour. No pushMsg call is made in debug.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Work priority 0</pre>
    </li>
    <li><a id="GeoPresence-attr-channel"></a><b>channel</b>
      <p><b>Applies to:</b> notify action<br>
      <b>Values:</b> <code>0</code>, <code>1</code>, <code>2</code>, <code>10</code><br>
      <b>Default:</b> <code>0</code></p>
      <p>The channel is passed to the installed pushMsg function. GeoPresence does not assign these numbers to a delivery service; destinations and optional speech depend on that function's configuration.</p>
      <p>Debug suppresses the entire call.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Action.Work channel 0</pre>
    </li>
  </ul>
  <h5>Rule</h5>
  <ul>
    <li><a id="GeoPresence-attr-enabled"></a><b>enabled</b>
      <p><b>Applies to:</b> Rule<br>
      <b>Values:</b> <code>1</code>, <code>0</code><br>
      <b>Default:</b> <code>1</code></p>
      <p>Include or exclude this rule from evaluation. Changing a shared rule requires all previously and newly selected residents to be debug or disabled and resets their sessions. Other residents can remain active.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.PERSONGarden enabled 1</pre>
    </li>
    <li><a id="GeoPresence-attr-trigger"></a><b>trigger</b>
      <p><b>Applies to:</b> Rule<br><b>Values:</b> arrival, enter, exit<br><b>Requirement:</b> Required</p>
      <ul><li><code>enter</code>/<code>exit</code>: an accepted observation of a selected location, or the first entry / last exit of a selected group.</li><li><code>arrival</code>: a confirmed return after a qualified trip, including the configured motion-dependent wait or phone confirmation. A startup Home observation is not sufficient.</li></ul>
      <p>Opening actions require arrival. Ordinary switch_on and notify actions may use any of these triggers. An enter rule at Home does not wait for arrival confirmation. FHEMWEB shows selectors for enter/exit and arrivalFilter for arrival; remove inapplicable stored selectors explicitly before changing the trigger.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.ORT trigger enter</pre>
    </li>
    <li><a id="GeoPresence-attr-residents"></a><b>residents</b>
      <p><b>Applies to:</b> Rule<br>
      <b>Selection:</b> One or more GeoPresence residents of this controller<br>
      <b>Requirement:</b> A non-empty resident list for every enabled rule</p>
      <p>Use the multiple-selection dialog to choose existing devices. Comma-separated existing GeoPresence resident names from the same controller, without spaces.</p>
      <p>Setting this attribute replaces the entire list. Keep all existing residents when extending a shared rule.</p>
      <p>Use Geo.PERSON, not rr_PERSON or an alias.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.Work residents Geo.PERSON,Geo.PERSON2</pre>
    </li>
    <li><a id="GeoPresence-attr-locationGroup"></a><b>locationGroup</b>
      <p><b>Applies to:</b> Rule with trigger enter or exit<br><b>Requirement:</b> Either one group or locations; not both</p>
      <p>A freely named location group, evaluated separately for each selected resident. Each resident must have at least one location carrying this tag in its groups attribute. Entry means first entered member; exit means the last explicitly entered member has left. Unknown members need not first be entered. Missing exits, geometry-based position inference and display expiry never generate a group exit.</p>
      <p>Use the same group tag on different residents' locations for a shared rule. Names are case-sensitive, start with a letter and contain up to 64 letters, digits, underscores, dots or hyphens. This filter is independent of FHEM's standard group attribute for display grouping.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.OfficeEntry locationGroup Offices</pre>
    </li>
    <li><a id="GeoPresence-attr-locations"></a><b>locations</b>
      <p><b>Applies to:</b> Rule with trigger enter or exit<br><b>Requirement:</b> Either a comma-separated location list or locationGroup; not both</p>
      <p>Match individual location events. A list is not a combined group: entering either listed location can trigger independently. Every selected location must belong to a resident in the rule, and each selected resident needs at least one matching location. The multiple-selection widget offers registered locations of this controller.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.ORT locations Geo.PERSON.ORT</pre>
    </li>
    <li><a id="GeoPresence-attr-afterExit"></a><b>afterExit</b>
      <p><b>Applies to:</b> Rule<br><b>Default:</b> unset, no extra exit prerequisite<br><b>Values:</b> location:DEVICE or group:GROUP</p>
      <p>Require an accepted, strictly earlier exit in the same resident's current trip. Group exit means leaving the last entered member. Reentry revokes the corresponding evidence. Completed return, rejected departure, geometry change, reset or clock discontinuity cannot transfer this history into another trip. Missing exits are not inferred.</p>
      <p>The prerequisite can be combined with arrivalFilter. It never replaces departure qualification, arrival confirmation, resident permissions or actuator checks. A Home exit does not remain a valid prerequisite after reentering Home.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.ReturnRoute afterExit group:Offices</pre>
    </li>
    <li><a id="GeoPresence-attr-arrivalFilter"></a><b>arrivalFilter</b>
      <p><b>Applies to:</b> Rule with trigger arrival<br><b>Values:</b> any, vehicle<br><b>Default:</b> any</p>
      <p>any adds no movement filter. vehicle requires recent automotive evidence or a confirmed remote trip without current contradictory walking, running or cycling. It does not identify a particular car. The result is retained through the deliberate Home confirmation wait.</p>
      <p>This filter works for any arrival action, including a light or notification. The garage_open adapter requires vehicle; door_open still requires personal door permission. Neither value permits an unqualified return.</p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.VehicleArrival arrivalFilter vehicle</pre>
    </li>
    <li><a id="GeoPresence-attr-action"></a><b>action</b>
      <p><b>Applies to:</b> Rule<br>
      <b>Requirement:</b> Required existing GeoPresence action device in the same controller; no default</p>
      <p>Select an existing action of this controller from the dropdown. References what the rule should execute, not the hardware target or a command string.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.PERSONGarden action Geo.Action.GardenLight</pre>
    </li>
    <li><a id="GeoPresence-attr-cooldown"></a><b>cooldown</b>
      <p><b>Applies to:</b> Rule<br>
      <b>Default:</b> <code>300</code> seconds<br>
      <b>Range:</b> integer 0&ndash;86400</p>
      <p>Minimum interval for notification/switch plans using the same action within a resident's state. This is not a global door/garage lockout.</p>
      <p>Duplicate events and repeated entries in the same visit remain suppressed even with 0; switch_on needs a new exit and entry for another visit.</p>
      <p><b>Example:</b></p>
      <pre style="white-space: pre-wrap; overflow-wrap: anywhere;">attr Geo.Rule.PERSONGarden cooldown 300</pre>
    </li>
  </ul>

  <a id="GeoPresence-readings"></a>
  <h4>Readings and logs</h4>
  <p><code>gp_roommate_error</code> reports a failed ROOMMATE status update. The current desired status is retried on the next timer pass, unless a newer status or context change supersedes it. The error clears when the update is accepted or ROOMMATE already has the requested status. Repeated identical failures produce one operational warning, followed by one recovery message. These retries never create opening permissions.</p>
  <p>A manual ROOMMATE Home event revokes that resident's pending arrival and output permissions, including inside another resident's status callback. During a status command, actual Home writes are attributed to the device, expected status and command context; foreign or additional Home writes revoke permissions immediately. Exactly one attributable own echo is ignored. Other receivers may delete and recreate the shared event view or rewrite eventMap text repeatedly without hiding the Home write. Outside the status command, normalized Home events and the actual Home reading with ROOMMATE state events identify manual arrivals. The configured Home event value also covers setreading updates after cache deletion when that value has a reading prefix, such as state: Zuhause. For repeatedly transformed prefixed values, FHEM's configured usr mapping translates the final event back to its Home meaning. Later mood changes preserve an already attributed own Home echo. Feedback for already dispatched actuators continues to be observed.</p>
  <p>Production resident readings prefixed with gp_ show snapshots such as phase, location, trip and door/garage results. Locations store production geometry in gp_geometry. These readings are diagnostic and do not restore executable permissions. Debug uses get explain with debug, get debugTrace and the separate diagnostic file instead of updating readings.</p>
  <p>The normal FHEM log contains English production area transitions, phone presence changes, opening requests and feedback, switch requests and messages handed to pushMsg. A message handoff is not a delivery receipt and door pulse confirmation is not proof that the door is physically open. Configured aliases, labels and message text are kept verbatim. The standard verbose attribute controls this normal output; detailed structured diagnostics go exclusively to logFile according to debugLog, even at verbose 5.</p>
  <p>Timer statistics and diagnostic files are never used to restore permissions. Logging failures do not change webhook acceptance or decision state. The timer reuses prepared configuration and static validation until relevant configuration changes; current source health and transport errors remain live. Unchanged idle ticks report zero device scans and configuration builds. The next tick is scheduled one second after completion; statistics distinguish callback work from delays caused elsewhere in FHEM.</p>
</div>

=end html

=cut
