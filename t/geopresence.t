use strict;
use warnings;
use utf8;
use Test::More;
use Time::Local qw(timegm);
use MIME::Base64 qw(encode_base64);
use POSIX qw(strftime);
use FindBin;
use File::Temp qw(tempdir);

our (%defs,%attr,%data,$init_done,$readingFnAttributes,$unicodeEncoding,$FW_ME);
our (@commands,@messages,@reading_events,@timers,%keys,$now,$mono,$on_command,$on_message,$on_log,$reading_calls);
our @logs;
$readingFnAttributes='';
sub setReadingsVal { $_[0]{READINGS}{$_[1]}={VAL=>$_[2],TIME=>$_[3]}; }
sub InternalTimer { push @timers, [@_]; }
sub RemoveInternalTimer { @timers=grep { $_->[2] != $_[0] } @timers; }
sub readingsBeginUpdate { $reading_calls++; $_[0]{CHANGED}=[]; }
sub readingsBulkUpdate {
    my ($d,$key,$value)=@_;
    $d->{READINGS}{$key}={VAL=>$value,TIME=>stamp($now)};
    push @{$d->{CHANGED}}, "$key: $value";
}
sub readingsEndUpdate {
    push @reading_events, [$_[0]{NAME},@{$_[0]{CHANGED}//[]}] if $_[1] && @{$_[0]{CHANGED}//[]};
}
sub CommandSet {
    my ($client,$command)=@_;
    my ($target)=split / /,$command,2;
    $defs{$target}{CL}=$client if $defs{$target};
    push @commands,$command;
    $on_command->($command) if $on_command;
    if ($command =~ /^(rr_\w+) state (\w+)$/) { reading($1,'state',$2,$now); }
    delete $defs{$target}{CL} if $defs{$target};
    return;
}
sub CommandAttr {
    my ($client,$command)=@_;
    my ($name,$key,$value)=split / /,$command,3;
    return attribute($name,$key,$value);
}
sub pushMsg { push @messages, [@_]; $on_message->(@_) if $on_message; }
sub Log3 { push @logs, [@_]; $on_log->(@_) if $on_log; }
sub diagnostic_lines {
    my ($c)=@_;
    my $path=GP_LogPath($c);
    return unless -f $path;
    open my $file,'<:encoding(UTF-8)',$path or die $!;
    my @lines=<$file>;
    close $file or die $!;
    return @lines;
}
require "$FindBin::Bin/lib/FhemKeyStore.pm";
sub deviceEvents { return $_[0]{CHANGED}; }
sub getAllAttr {
    my ($name)=@_;
    return join(' ',qw(alias room group icon verbose comment eventMap userReadings disable),
        ($defs{$name}{TYPE}//'') eq 'ROOMMATE' ? qw(rr_locationUnderway rr_geofenceUUIDs) : (),
        keys %{$attr{$name}//{}});
}
sub setNotifyDev { $_[0]{NOTIFYDEV}=$_[1]; }
require "$FindBin::Bin/../FHEM/98_GeoPresence.pm";
{
    no warnings qw(redefine once);
    *GP_Now=sub {$now};
    *GP_Mono=sub {$mono};
    # Only socket creation is replaced here. The separate integration suite
    # exercises the real listener, FHEM select loop and network boundary.
    *GP_OpenHTTP=sub {
        my ($c,$port)=@_;
        $c->{helper}{gp_http}={port=>$port,address=>GP_Attr($c->{NAME},'webhookBindAddress','127.0.0.1'),
            allowed_peers=>GP_Attr($c->{NAME},'webhookAllowedPeers','127.0.0.1'),server=>{NAME=>'test.listener'},clients=>{}};
        return;
    };
}

sub stamp { return strftime('%Y-%m-%d %H:%M:%S',localtime($_[0])); }
sub iso { return strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($_[0])); }
sub reading { setReadingsVal($defs{$_[0]},$_[1],$_[2],stamp($_[3])); }
sub device {
    my ($name,$type)=@_;
    $defs{$name}={NAME=>$name,TYPE=>$type,READINGS=>{}};
    config_event("DEFINED $name") if $init_done && $type ne 'GeoPresence';
    return $defs{$name};
}
sub gp_define {
    my ($name,$definition)=@_;
    my $d=device($name,'GeoPresence');
    $d->{DEF}=$definition;
    my $err=GeoPresence_Define($d,"$name GeoPresence $definition");
    die "define $name: $err" if defined $err;
    return $d;
}
sub attribute {
    my ($name,$key,$value)=@_;
    my $err=GeoPresence_Attr('set',$name,$key,$value);
    die "attr $name $key: $err" if defined $err;
    $attr{$name}{$key}=$value;
    config_event("ATTR $name $key $value") if $init_done;
    return;
}
sub delete_attributes {
    my ($name,$pattern)=@_;
    my $error=GeoPresence_Attr('del',$name,$pattern);
    return $error if defined $error;
    if (defined $pattern) {
        delete $attr{$name}{$_} for grep {/^$pattern$/} keys %{$attr{$name}//{}};
    } else { delete $attr{$name}; }
    config_event('DELETEATTR '.$name.(defined($pattern)?' '.$pattern:'')) if $init_done;
    return;
}
sub config_event { GeoPresence_Notify($defs{GP},{NAME=>'global',CHANGED=>[@_]}); }
sub mode { my ($name,$value)=@_; my $error=GeoPresence_Set($defs{$name},$name,'mode',$value); die $error if defined $error; return; }
sub rename_device {
    my ($old,$new)=@_;
    my $d=delete $defs{$old} or die "Missing rename source $old";
    $defs{$new}=$d;$d->{NAME}=$new;
    $attr{$new}=delete $attr{$old} if exists $attr{$old};
    GeoPresence_Rename($new,$old) if $d->{TYPE} eq 'GeoPresence';
    GeoPresence_Notify($_,{NAME=>'global',CHANGED=>["RENAMED $old $new"]})
        for grep {($_->{TYPE}//'') eq 'GeoPresence' && ($_->{SUBTYPE}//'') eq 'controller'} values %defs;
    return $d;
}
sub fixture {
    my %options=@_;
    %defs=();%attr=();%data=();%keys=();@commands=();@messages=();@reading_events=();@timers=();$on_command=undef;
    $on_log=undef; $on_message=undef; $unicodeEncoding=1;
    $reading_calls=0;
    @logs=();
    $now=timegm(0,0,12,11,8,2026); $mono=1000; $init_done=0;
    device('rr_Test','ROOMMATE'); reading('rr_Test','state','home',$now);
    $attr{rr_Test}{rr_locationUnderway}='underway'; $attr{rr_Test}{alias}='Test';
    for my $n (1..3) {device("p$n",'PRESENCE');$defs{"p$n"}{INTERVAL_NORMAL}=60;}
    device('door','dummy');device('contact','dummy');device('feedback','DOIF');
    device('garage','dummy');device('gate','dummy');device('upper','dummy');device('lower','dummy');
    my $c=gp_define('GP','controller'); $attr{GP}=$options{omit_webhook_port} ? {}:{webhookPort=>8090}; GP_StoreMode($defs{GP},'debug');
    $attr{GP}{$_}=$options{$_} for grep {exists $options{$_}} qw(action_max_age zone_display_max_age);
    gp_define('Geo.Test','resident GP rr_Test');
    $attr{'Geo.Test'}={deviceId=>'DEVICE',webhookUser=>'user',sourceMode=>$options{source_mode}//'geofency_phone',phoneProxies=>'p1,p2,p3',phoneSignalMode=>'measurement',allowDoor=>1,allowGarage=>1}; GP_StoreMode($defs{'Geo.Test'},'active');
    $keys{'GeoPresence_Geo.Test_auth'}='a'x32 . ':'.Digest::SHA::sha256_hex('a'x32 . ':'.'password123456789012345678');
    my @zones=([Home=>'home',0,50],[Drive=>'approach',0,250],[Outer=>'outer',0,4500],
        [Work=>'place',0.1,100],[Work2=>'place',0.1005,100],[Checkpoint=>'place',0.01,100],[Sternensteg=>'place',0.07,500]);
    for my $z (@zones) {
        gp_define("Z.$z->[0]","location Geo.Test $z->[1]");
        $attr{"Z.$z->[0]"}={zoneId=>$z->[0],label=>$z->[0]};
        $attr{"Z.$z->[0]"}{groups}='Work' if $z->[0] =~ /^Work/;
        reading("Z.$z->[0]",'gp_geometry',JSON::PP::encode_json({lat=>$z->[2],lon=>0,radius=>$z->[3],
            time=>$now-1000,changed=>$now-1000,id=>lc($z->[0]),device=>'device',blocked=>0}),$now-1000);
    }
    $attr{'Z.Home'}{label}=$options{home_label} if exists $options{home_label};
    gp_define('A.Door','action GP door_open'); $attr{'A.Door'}={target=>'door',command=>'lock unlocked',contact=>'contact',feedbackDevice=>'feedback'};
    gp_define('A.Garage','action GP garage_open'); $attr{'A.Garage'}={target=>'garage',command=>'on',stateDevice=>'gate',upperContact=>'upper',lowerContact=>'lower'};
    gp_define('A.Msg','action GP notify'); $attr{'A.Msg'}={message=>'%resident% arrived',channel=>0,priority=>0};
    for my $row ([Door=>'arrival','A.Door'],[Late=>'arrival','A.Garage'],[Work=>'enter','A.Msg']) {
        gp_define("R.$row->[0]",'rule GP');
        $attr{"R.$row->[0]"}={trigger=>$row->[1],action=>$row->[2],residents=>'Geo.Test'};
    }
    $attr{'R.Late'}{arrivalFilter}='vehicle'; $attr{'R.Work'}{locationGroup}='Work';
    $defs{GP}{READINGS}{mode}{VAL}='active'; $init_done=1;
    GP_ResetController($c); GeoPresence_Timer($c);
    return ($c,GP_Config($c,'Geo.Test'));
}
sub advance { $now+=$_[0];$mono+=$_[0]; }
sub ev {
    my ($zone,$entry,$time,$motion)=@_;
    return {kind=>'geo',zone=>"Z.$zone",entry=>$entry,time=>$time,received=>$time,
        motion=>$motion//'unknown',key=>"$zone:$entry:$time"};
}
sub new_state { GP_NewState($now,$mono,'test'); }
sub process {
    my ($s,$cfg,$zone,$entry,$motion)=@_;
    my $e=ev($zone,$entry,$now,$motion);
    $e->{zone}=$cfg->{zone_ids}{lc $zone}[0] if @{$cfg->{zone_ids}{lc $zone}//[]};
    GP_Process($s,$cfg,$e,$now,$mono);
    return $s->{intents};
}
# Existing actor/permission regressions request a completed Home arrival.
# Timing regressions below use process() directly and inspect the pending phase.
sub arrive {
    my ($s,$cfg,$motion)=@_;
    process($s,$cfg,'Home',1,$motion);
    return complete_arrival($s,$cfg);
}
sub complete_arrival {
    my ($s,$cfg)=@_;
    if (my $p=$s->{arrival}) {
        advance($p->{due_mono}-$mono) if $p->{due_mono}>$mono;
        GP_ConfirmArrival($s,$cfg,$now,$mono);
    }
    return $s->{intents};
}
sub finish_arrivals {
    my ($c)=@_;
    my @pending=map {values %$_} @{$c->{helper}{gp}}{qw(prod debug)};
    my @due=sort {$b<=>$a} map {$_->{arrival}{due_mono}-($_->{debug_offset}//0)} grep {$_->{arrival}} @pending;
    advance($due[0]-$mono) if @due && $due[0]>$mono;
    GeoPresence_Timer($c);
}
sub negative_samples { return { map { $_=>{value=>'absent',time=>$now,ttl=>150,healthy=>1} } qw(p1 p2 p3)}; }
sub phone_tick {
    my ($s,$cfg,$samples)=@_;
    my $event=GP_Phone($s,$cfg,$samples,$now,$mono);
    GP_Process($s,$cfg,$event,$now,$mono) if $event;
    return $event;
}
sub house_fixture {
    my ($c)=fixture();
    for my $n (4,5) {device("p$n",'PRESENCE');$defs{"p$n"}{INTERVAL_NORMAL}=60;}
    $attr{'Geo.Test'}{phoneProxies}='p1,p2,p3,p4,p5';
    config_event('ATTR Geo.Test phoneProxies p1,p2,p3,p4,p5');
    return ($c,GP_Config($c,'Geo.Test'),GP_State($c,'Geo.Test',0));
}
sub house_samples {
    my (%values)=@_;
    return {map {$_=>{value=>$values{$_}//'absent',time=>$now,ttl=>150,healthy=>1}} qw(p1 p2 p3 p4 p5)};
}
sub feed_house_phone {
    my ($c,$cfg,$s,$samples)=@_;
    my $event=GP_Phone($s,$cfg,$samples,$now,$mono);
    GP_Process($s,$cfg,$event,$now,$mono) if $event;
    GP_TickState($s,$cfg,$now,$mono);
    GP_Dispatch($c,$cfg->{resident},$cfg,$s,0,$now,$mono);
    GP_Publish($c,$cfg->{resident},$cfg,$s);
    return $event;
}
sub actor_fresh {
    reading('contact','state','closed',$now);reading('feedback','pulse_state','idle',$now);
    reading('gate','state','off',$now);reading('upper','state','open',$now);reading('lower','state','closed',$now);
}
sub shared_actor_fixture {
    my ($c)=fixture();
    {
        local $init_done=0;
        device('rr_Other','ROOMMATE');$attr{rr_Other}{rr_locationUnderway}='underway';
        gp_define('Geo.Other','resident GP rr_Other');
        $attr{'Geo.Other'}={%{$attr{'Geo.Test'}},deviceId=>'other-device',webhookUser=>'other-user'};
        $keys{'GeoPresence_Geo.Other_auth'}=$keys{'GeoPresence_Geo.Test_auth'};
        GP_StoreMode($defs{'Geo.Other'},'active');
        for my $n (sort grep {/^Z\./} keys %defs) {
            (my $other=$n)=~s/^Z\./O./;
            gp_define($other,'location Geo.Other '.$defs{$n}{ROLE});
            $attr{$other}={%{$attr{$n}}};
            my $g=JSON::PP::decode_json(GP_Read($n,'gp_geometry','{}'));
            $g->{device}='other-device';reading($other,'gp_geometry',JSON::PP::encode_json($g),$now-1000);
        }
        $attr{$_}{residents}='Geo.Test,Geo.Other' for qw(R.Door R.Late R.Work);
    }
    GP_ResetController($c);GeoPresence_Timer($c);
    return ($c,GP_Config($c,'Geo.Test'),GP_Config($c,'Geo.Other'));
}
sub output_intent {
    my ($s,$cfg,$kind,$params)=@_;
    my $e={time=>$now,received=>$now};
    my %arrival;
    if (GP_IsOpening($kind)) {
        $s->{last_trip}//={id=>'adapter-trip',armed=>1};
        %arrival=(trigger=>'arrival',trip=>$s->{last_trip}{id});
    }
    return {kind=>$kind,generation=>$s->{generation},output_revision=>$s->{output_revision},
        expires_mono=>$mono+GP_ActionExpiry($cfg,$e)-$now,e=>$e,params=>$params,%arrival};
}
sub actor_event {
    my ($c,$device,$key,$value,$time)=@_;
    reading($device,$key,$value,$time//$now);
    local $defs{$device}{CHANGED}=["$key: $value"];
    GeoPresence_Notify($c,$defs{$device}) if grep {$_ eq $device} split /,/,$c->{NOTIFYDEV};
}
sub roommate_event {
    my ($c,$name,$status,@events)=@_;
    reading($name,'state',$status,$now);
    local $defs{$name}{CHANGED}=@events ? [@events]:["state: $status"];
    $defs{$name}{CHANGEDWITHSTATE}=[];
    GeoPresence_Notify($c,$defs{$name});
    delete $defs{$name}{CHANGEDWITHSTATE};
}
sub form {
    my ($cfg,$zone,$entry,$time,%extra)=@_;
    my $z=$cfg->{zones}{"Z.$zone"};
    my %p=(device=>'DEVICE',id=>$zone,entry=>$entry,date=>iso($time),latitude=>$z->{lat},longitude=>0,radius=>$z->{radius},%extra);
    return join '&',map { my $v=$p{$_}; $v =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X',ord($1))/eg; "$_=$v" } sort keys %p;
}
sub http {
    my ($c,$body,$path,$auth)=@_;
    if (defined($path) && $path eq '1') { $path='/fhem/geopresence'; $body.='&isTest=true'; }
    return GP_HTTP($c,'POST',$path//'/fhem/geopresence',{'content-type'=>'application/x-www-form-urlencoded',
        authorization=>$auth//'Basic '.encode_base64('user:password123456789012345678','')},$body);
}

subtest 'strict time and request decoding' => sub {
    my ($utc,$key)=GP_ParseTime('2026-09-11T12:00:00.123000Z');
    my ($offset,$key2)=GP_ParseTime('2026-09-11T14:00:00.123+02:00');
    is($utc,$offset,'offsets normalize');is($key,$key2,'fractional keys normalize');
    is((GP_ParseTime('2026-09-11T12:00:00.000Z'))[1],(GP_ParseTime('2026-09-11T12:00:00Z'))[1],'zero fractions normalize');
    for my $bad ('2026-02-30T12:00:00Z','2026-09-11T24:00:00Z','today','2026-09-11T12:00:00') {
        my ($t)=GP_ParseTime($bad); ok(!defined($t),"reject $bad");
    }
    my ($p,$err)=GP_DecodeForm('name=Work%26Home&entry=1');is($p->{name},'Work&Home','split before percent decoding');
    for my $bad ('entry=1&entry=0','id=%GG','id=%00','id=%FF') {
        my ($v,$e)=GP_DecodeForm($bad);ok($e && !$v,"reject $bad");
    }
};

subtest 'Geofency multiline metadata is harmless but decision fields remain strict' => sub {
    my ($c,$cfg)=fixture();$defs{GP}{READINGS}{mode}{VAL}='debug';advance(40);
    like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','mode','learning'),qr/^Learning/,'learning starts');
    my $body=form($cfg,'Home',1,$now,name=>'Home',address=>"PRIVATE_ADDRESS\r\nSECOND_LINE\tZIP",notes=>"PRIVATE_NOTES\nLINE");
    my ($p,$err,$meta)=GP_DecodeForm($body);
    is($err,undef,'CR/LF and tabs in unused text fields are valid');
    like($meta->{ignored_multiline},qr/address/,'metadata identifies the field without its value');
    is_deeply([http($c,$body,1)],[200,'OK learning captured; no actions'],'multiline metadata no longer prevents learning');
    my $learned=GeoPresence_Get($c,'GP','learnedLocations','Geo.Test','format=json');
    like($learned,qr/Home/,'location was captured');
    unlike($learned,qr/PRIVATE_/,'unused metadata is not retained');
    for my $field (qw(device id date entry name latitude longitude radius motion currentLatitude currentLongitude)) {
        my ($parsed,$error)=GP_DecodeForm("$field=private%0Avalue");
        ok(!$parsed,"$field is never silently normalized into decision data");
        is($error,"Control character U+000A in $field","$field diagnostic names the codepoint and field only");
        unlike($error,qr/private|value/,'value is not disclosed');
    }
    for my $code (qw(00 01 08 0B 0C 0E 1F 7F)) {
        ok(!defined((GP_DecodeForm("address=private%$code"))[0]),"reject non-text control $code even in metadata");
    }
    ok(!defined((GP_DecodeForm('na%0Ame=value'))[0]),'control characters in keys remain invalid');
    is((http($c,$body.'&cmd=set+door+lock+unlocked',1))[0],400,'multiline metadata cannot conceal a FHEM command');
    is(scalar @commands,0,'learning and rejected inputs issue no commands');
    is(scalar @messages,0,'learning and rejected inputs issue no notifications');
};

subtest 'diagnostic logs are bounded, private and independent of debug state' => sub {
    my ($c,$cfg)=fixture();$defs{GP}{READINGS}{mode}{VAL}='debug';$attr{GP}{verbose}=4;advance(40);
    my $dir=tempdir(CLEANUP=>1);
    my $epoch=$c->{helper}{gp}{epoch};
    like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','mode','learning'),qr/^Learning/,'learning started');
    attribute('GP','logFile',"$dir/geopresence-%Y-%m.log");
    is($c->{helper}{gp}{epoch},$epoch,'logging configuration does not reset the controller');
    ok($c->{helper}{gp}{learning}{'Geo.Test'},'logging configuration preserves the learning window');
    my $body=form($cfg,'Home',1,$now,address=>"ADDRESS_SECRET\r\nSTREET_SECRET",wifiSSID=>'WIFI_SECRET');
    is((http($c,$body,1))[0],200,'learning succeeds while logging');
    is((http($c,form($cfg,'Home',1,$now,name=>"NAME_SECRET\nINJECTED"),1))[0],400,'typed-field error is logged');
    my $auth='Basic '.encode_base64('UNKNOWN_USER:WRONG_PASSWORD','');
    is((http($c,$body,1,$auth))[0],401,'authentication rejection is logged without credentials');
    my $status=JSON::PP::decode_json(GeoPresence_Get($c,'GP','logStatus','format=json'));
    ok(-f $status->{file},'module created a monthly log');
    is($status->{error},'','no file error');
    open my $file,'<',$status->{file} or die $!;my $text=do {local $/;<$file>};close $file;
    like($text,qr/"status":"200"/,'successful HTTP response logged');
    like($text,qr/Control character U\+000A in name/,'rejection has an actionable safe diagnostic');
    like($text,qr/"ignored_multiline":"address"/,'accepted multiline field is visible');
    unlike($text,qr/ADDRESS_SECRET|STREET_SECRET|WIFI_SECRET|NAME_SECRET|INJECTED|UNKNOWN_USER|WRONG_PASSWORD|password123|Authorization|Basic /i,'no submitted values or credentials in logs');
    my $s=GP_State($c,'Geo.Test',1);GP_Trace($s,$now,'would execute; debug suppressed',{kind=>'door_open',target=>'door'});
    my ($commands,$messages,$readings)=(scalar @commands,scalar @messages,$reading_calls);
    GP_LogTrace($c,'Geo.Test',$s,1);my $count=scalar diagnostic_lines($c);
    GP_LogTrace($c,'Geo.Test',$s,1);is(scalar diagnostic_lines($c),$count,'timer does not re-log previous decisions');
    is_deeply([scalar @commands,scalar @messages,$reading_calls],[$commands,$messages,$readings],'file diagnostics cause no commands, messages or Reading callbacks');
    my $old=$status->{file};advance(31*86400);GP_Log($c,3,'test',{reason=>'rotated'});
    isnt(GP_LogPath($c),$old,'monthly filename advances');ok(-f GP_LogPath($c),'next monthly file created on first entry');
    attribute('GP','logFile',"$dir/missing/diagnostic.log");
    mode('Geo.Test','debug');
    is((http($c,'entry=%0A',1))[0],400,'log write failure does not break the HTTP response');
    like(JSON::PP::decode_json(GeoPresence_Get($c,'GP','logStatus','format=json'))->{error},qr/Cannot open/,'file failure remains visible through get logStatus');
    attribute('GP','logFile',"$dir/bounded.log");delete $c->{helper}{gp_log_rate};@logs=();
    GP_Log($c,2,'test',{reason=>'bounded'}) for 1..305;
    my @bounded=diagnostic_lines($c);
    is(scalar @bounded,301,'300 entries plus one suppression message per minute');
    like($bounded[-1],qr/log_rate_limit/,'suppression is visible');advance(60);
    GP_Log($c,2,'test',{reason=>'resumed'});is(scalar diagnostic_lines($c),302,'logging resumes next minute');
    is(scalar @logs,0,'structured diagnostics are not copied into the FHEM log');
};

subtest 'validated configuration and no hardcoded actions' => sub {
    my ($c,$cfg)=fixture();is_deeply([GP_Validate($c,'Geo.Test',1)],[],'valid full configuration');
    advance(40);
    GP_UpdateGeometry($c,'Geo.Test',0,GP_State($c,'Geo.Test',0),
        {kind=>'geo',zone=>'Z.Home',time=>$now,received=>$now,geometry=>{lat=>0,lon=>0,radius=>300}},$cfg,$now);
    like(join(' ',@{GP_Config($c,'Geo.Test')->{geometry_errors}}),qr/not contained/,'invalid nested circles block opening');
};

subtest 'GPS jitter never arms by timeout alone' => sub {
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);
    arrive($s,$cfg);advance(20);process($s,$cfg,'Home',0);
    advance(120);GP_TickState($s,$cfg,$now,$mono);is($s->{phase},'away','absence status after grace');
    ok(!$s->{trip}{armed},'timer does not arm');
    arrive($s,$cfg);is(scalar @{$s->{intents}},0,'no opening on jitter return');
    is($s->{phase},'home','home repaired');
};

subtest 'remote trip, no opening at approach, confirmed arrival and duplicates' => sub {
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);
    process($s,$cfg,'Work',0);ok($s->{trip}{armed},'work exit alone confirms departure');
    is($s->{trip}{scope},'remote','remote from geometry');advance(90);
    my $i=process($s,$cfg,'Drive',1);is_deeply([map {$_->{kind}} @$i],[],'approach alone cannot open');
    advance(10);$i=arrive($s,$cfg);
    is_deeply([map {$_->{kind}} @$i],['door_open','garage_open'],'both openings await confirmed Home arrival');
    is($s->{phase},'home','arrived');ok(!$s->{trip},'trip consumed');
    arrive($s,$cfg);is(scalar @{$s->{intents}},0,'duplicate no output');
    advance(1);arrive($s,$cfg);is(scalar @{$s->{intents}},0,'new home event no new permission');
};

subtest 'local walk and motion override' => sub {
    my ($c,$cfg)=fixture();
    for my $case (['Drive','unknown',1],['Outer','walking',1],['Drive','automotive',2],['Outer','unknown',2]) {
        my $s=new_state();advance(40);process($s,$cfg,$case->[0],0);advance(90);
        my $i=arrive($s,$cfg,$case->[1]);is(scalar(@$i),$case->[2],"$case->[0] return $case->[1]");
    }
};

subtest 'missing or inconclusive arrival motion preserves fresh foot evidence' => sub {
    for my $foot (qw(walking running cycling)) {
        for my $missing (undef,'unknown','stationary') {
            my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
            advance(40);process($s,$cfg,'Work',0);advance(90);actor_fresh();
            process($s,$cfg,'Drive',1,$foot);my $observed=$now;
            GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
            advance(10);arrive($s,$cfg,$missing);
            is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],"$foot survives ".($missing//'missing')." at Home");
            is($s->{motion},$foot,'last meaningful motion remains visible');
            is($s->{motion_time},$observed,'inconclusive update does not refresh evidence time');
            GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
            is(scalar(grep {$_ eq 'garage on'} @commands),0,'neither arrival point opens garage');
        }
    }
};

subtest 'retained motion expires and is bounded by the arrival section' => sub {
    for my $boundary (qw(expiry exit timeout new_trip remote)) {
        my ($c,$cfg)=fixture();$attr{'R.Early'}{enabled}=0;$cfg=GP_Config($c,'Geo.Test');
        $cfg->{approach_timeout}=30 if $boundary eq 'timeout';
        my $s=new_state();advance(40);process($s,$cfg,'Work',0);advance(90);
        process($s,$cfg,'Drive',1,'walking');my $observed=$now;
        if ($boundary eq 'expiry') {
            advance(170);process($s,$cfg,'Drive',1);
            is($s->{motion_time},$observed,'empty approach does not extend walking lifetime');
            advance(11);
        } elsif ($boundary eq 'exit') {
            advance(1);process($s,$cfg,'Drive',0);advance(10);
        } elsif ($boundary eq 'timeout') {
            advance(31);GP_TickState($s,$cfg,$now,$mono);
        } elsif ($boundary eq 'new_trip') {
            advance(1);arrive($s,$cfg);
            advance(1);process($s,$cfg,'Work',0);advance(61);
        } else {
            advance(1);process($s,$cfg,'Work',0);advance(10);
        }
        arrive($s,$cfg);
        is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open','garage_open'],"$boundary ends the prior walking veto");
    }
    for my $sequence ([qw(automotive walking)],[qw(walking automotive)]) {
        my ($c,$cfg)=fixture();$attr{'R.Early'}{enabled}=0;$cfg=GP_Config($c,'Geo.Test');my $s=new_state();
        advance(40);process($s,$cfg,'Work',0);advance(90);process($s,$cfg,'Drive',1,$sequence->[0]);
        advance(10);process($s,$cfg,'Drive',1,$sequence->[1]);advance(10);arrive($s,$cfg);
        is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open','garage_open'],"fresh automotive remains valid for @$sequence then missing");
    }
};

subtest 'zone-specific garage rules see the current arrival motion before evaluation' => sub {
    my ($c,$cfg)=fixture();
    $attr{'R.Late'}{trigger}='enter';$attr{'R.Late'}{locations}='Z.Home';
    $cfg=GP_Config($c,'Geo.Test');my $s=new_state();
    advance(40);process($s,$cfg,'Work',0);advance(90);arrive($s,$cfg,'walking');
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'zone_enter rule cannot use remote before seeing Home walking');
};

subtest 'missing locations and phone fallback' => sub {
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Work',1);advance(200);
    my $samples=negative_samples();GP_Phone($s,$cfg,$samples,$now,$mono);
    advance(180);GP_Phone($s,$cfg,negative_samples(),$now,$mono);
    advance(10);$samples=negative_samples();$samples->{p1}{value}='present';
    my $e=GP_Phone($s,$cfg,$samples,$now,$mono);ok($e->{arrival},'phone arrival after absent');
    GP_Process($s,$cfg,$e,$now,$mono);is(scalar @{$s->{intents}},2,'door and garage via phone');
    is($s->{phase},'home','phone repairs missed geo arrival');
};

subtest 'short walk uses qualified new negative measurements' => sub {
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Home',0);advance(1);
    phone_tick($s,$cfg,negative_samples());
    advance(179);phone_tick($s,$cfg,negative_samples());ok(!$s->{trip}{armed},'not before 180s');
    advance(1);phone_tick($s,$cfg,negative_samples());ok($s->{trip}{armed},'180s qualifies walk');
    advance(1);arrive($s,$cfg);is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'walk opens only door');
    $s=new_state();advance(40);process($s,$cfg,'Home',0);my $old=negative_samples();
    phone_tick($s,$cfg,$old);advance(180);phone_tick($s,$cfg,$old);
    ok(!$s->{trip}{armed},'stale samples do not qualify');
    $s=new_state();advance(40);process($s,$cfg,'Home',0);advance(1);$old=negative_samples();
    $_->{ttl}=270 for values %$old;
    phone_tick($s,$cfg,$old);advance(180);phone_tick($s,$cfg,$old);
    ok(!$s->{trip}{armed},'even a long TTL cannot turn one sample into a measurement sequence');
    advance(1);phone_tick($s,$cfg,negative_samples());ok($s->{trip}{armed},'renewed measurements qualify after continuous interval');
};

subtest 'phone-only outage and continuous presence' => sub {
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);
    GP_Phone($s,$cfg,negative_samples(),$now,$mono);advance(180);GP_Phone($s,$cfg,negative_samples(),$now,$mono);
    advance(1);my $samples=negative_samples();$samples->{p1}{value}='present';
    my $e=GP_Phone($s,$cfg,$samples,$now,$mono);GP_Process($s,$cfg,$e,$now,$mono);
    is(scalar @{$s->{intents}},0,'power-cycling phone does not open');
    $s=new_state();advance(40);$samples=negative_samples();$samples->{p1}{value}='present';
    $e=GP_Phone($s,$cfg,$samples,$now,$mono);GP_Process($s,$cfg,$e,$now,$mono);
    advance(1);process($s,$cfg,'Drive',0);advance(90);$samples=negative_samples();$samples->{p1}{value}='present';
    $e=GP_Phone($s,$cfg,$samples,$now,$mono);GP_Process($s,$cfg,$e,$now,$mono);
    is(scalar @{$s->{intents}},0,'continuous phone presence contradicts false departure');
};

subtest 'stale and reordered events cannot reopen trips' => sub {
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Work',0);
    my $old=$now;advance(90);arrive($s,$cfg);
    GP_Process($s,$cfg,ev('Outer',0,$old),$now,$mono);ok(!$s->{trip},'late outer exit cannot rearm');
    my $e=ev('Home',1,$now-3600);GP_Process($s,$cfg,$e,$now,$mono);is(scalar @{$s->{intents}},0,'hours late no opening');
    $s=new_state();advance(40);process($s,$cfg,'Drive',0);process($s,$cfg,'Drive',1);
    ok($s->{conflict},'simultaneous enter/exit quarantined');
};

subtest 'startup without a qualified checkpoint does not reuse old permissions' => sub {
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Work',0);my $before=$now;
    advance(1);$s=new_state();advance(40);arrive($s,$cfg);
    is(scalar @{$s->{intents}},0,'new arrival alone after restart cannot open');
    GP_Process($s,$cfg,ev('Work',0,$before),$now,$mono);ok(!$s->{trip},'old departure cannot restart trip');
    advance(1);process($s,$cfg,'Work',0);advance(90);arrive($s,$cfg);
    is(scalar @{$s->{intents}},2,'new departure and arrival recover automatic operation');
};

subtest 'helper waypoint confirms departure without opening' => sub {
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Checkpoint',1);
    ok($s->{trip}{armed},'helper outside approach arms');is($s->{trip}{scope},'local','helper inside outer stays local');
    is(scalar @{$s->{intents}},0,'helper never opens');advance(90);arrive($s,$cfg);
    is(scalar @{$s->{intents}},1,'door only for local helper');
};

subtest 'webhook port defaults on initial setup and attribute removal without hiding invalid values' => sub {
    my ($c)=fixture(omit_webhook_port=>1);
    ok(!exists $attr{GP}{webhookPort},'initial controller has no explicit port');
    is(GP_HTTPConfigError($c),undef,'absent port is a valid transport configuration');
    is($c->{helper}{gp_http}{port},8090,'initial listener uses documented default port');
    ok($c->{helper}{gp}{ready},'default transport allows resident processing');
    is_deeply([GP_Validate($c)],[],'otherwise complete configuration validates without a port attribute');

    mode('GP','debug');
    attribute('GP','webhookPort','8091');GeoPresence_Timer($c);
    is($c->{helper}{gp_http}{port},8091,'explicit port overrides default');
    is(GeoPresence_Attr('del','GP','webhookPort',undef),undef,'port attribute can be deleted');
    delete $attr{GP}{webhookPort};GeoPresence_Timer($c);
    is($c->{helper}{gp_http}{port},8090,'attribute removal rebinds listener to default port');
    ok($c->{helper}{gp}{ready},'controller remains ready after restoring the default');

    for my $port ('','0','1023','65536','8090.5','invalid') {
        local $attr{GP}{webhookPort}=$port;
        like(GP_HTTPConfigError($c),qr/webhookPort must be an integer from 1024 to 65535/,
            "explicit invalid port '$port' is rejected rather than defaulted");
        like(GP_EnsureHTTP($c),qr/webhookPort must be an integer from 1024 to 65535/,
            "listener setup rejects explicit invalid port '$port'");
        ok(!$c->{helper}{gp_http},'invalid explicit configuration closes listener');
    }
    is(GP_EnsureHTTP($c),undef,'missing attribute restores valid transport after an invalid value');
    is($c->{helper}{gp_http}{port},8090,'listener recovers on default port');
};

subtest 'remote proxy binding requires explicit valid IPv4 peers and preserves local defaults' => sub {
    my ($c,$cfg)=fixture();mode('GP','debug');GeoPresence_Timer($c);
    is($c->{helper}{gp_http}{address},'127.0.0.1','default listener stays local');
    is($c->{helper}{gp_http}{allowed_peers},'127.0.0.1','default accepts only local connections');
    for my $address ('0.0.0.0','256.0.0.1','192.000.2.20','smart-house','::1','192.0.2.20/24','224.1.2.3','') {
        like(GeoPresence_Attr('set','GP','webhookBindAddress',$address),qr/IPv4/,"invalid or wildcard bind rejected: $address");
    }
    for my $peers ('','*','0.0.0.0','192.0.2.0/24','gateway','192.0.2.10,','192.0.2.10,192.0.2.10','::1') {
        like(GeoPresence_Attr('set','GP','webhookAllowedPeers',$peers),qr/IPv4/,"invalid peer list rejected: $peers");
    }
    attribute('GP','webhookBindAddress','192.0.2.20');GeoPresence_Timer($c);
    like(GP_HTTPConfigError($c),qr/explicit webhookAllowedPeers/,'LAN listener needs an explicit peer list');
    ok(!$c->{helper}{gp_http},'invalid network configuration opens no listener');
    attribute('GP','webhookAllowedPeers','192.0.2.10,192.0.2.20');GeoPresence_Timer($c);
    is(GP_HTTPConfigError($c),undef,'known topology validates');
    is($c->{helper}{gp_http}{address},'192.0.2.20','configured interface is passed to listener');
    is($c->{helper}{gp_http}{allowed_peers},'192.0.2.10,192.0.2.20','gateway and local diagnostic address explicitly selected');
    local $attr{GP}{webhookAllowedPeers}='*';GeoPresence_Timer($c);
    ok(!$c->{helper}{gp_http},'invalid restored configuration also closes listener');
};

subtest 'HTTP authentication binding, formats, bounds and debug' => sub {
    my ($c,$cfg)=fixture();advance(40);
    my $body=form($cfg,'Work',0,$now);
    is((http($c,$body,undef,'Basic '.encode_base64('user:wrong','')))[0],401,'wrong password');
    is((http($c,form($cfg,'Work',0,$now,device=>'other')))[0],422,'authenticated user cannot impersonate device');
    is((http($c,form($cfg,'Work',0,$now,latitude=>91)))[0],422,'invalid latitude rejected');
    is((http($c,$body.'/x','/fhem/geopresence-extra'))[0],404,'exact path required');
    is((http($c,'a'x17000))[0],413,'payload bounded');
    is((http($c,$body,1))[0],200,'debug accepted while active');advance(3);GeoPresence_Timer($c);
    is(scalar @commands,0,'debug no commands');is(scalar @messages,0,'debug no messages');
    advance(90);http($c,form($cfg,'Home',1,$now),1);advance(3);GeoPresence_Timer($c);
    finish_arrivals($c);
    is(scalar @commands,0,'debug arrival no commands');is(scalar @messages,0,'debug arrival no messages');
    like(GeoPresence_Get($c,'GP','debugTrace','Geo.Test','format=json'),qr/would execute/,'debug explains intended action');
};

subtest 'actuator adapter and duplicate resident events' => sub {
    my ($c,$cfg)=fixture();advance(40);actor_fresh();
    http($c,form($cfg,'Work',0,$now));advance(3);GeoPresence_Timer($c);advance(90);actor_fresh();
    my $body=form($cfg,'Home',1,$now);http($c,$body);http($c,$body);advance(3);GeoPresence_Timer($c);
    finish_arrivals($c);
    is(scalar(grep {$_ eq 'door lock unlocked'} @commands),1,'one door dispatch');
    is(scalar(grep {$_ eq 'garage on'} @commands),1,'one garage dispatch');
    is(GP_Read('rr_Test','state',''),'home','ROOMMATE synchronized');
};

subtest 'ambiguous hardware state and debug input never call actuators' => sub {
    my ($c,$cfg)=fixture();advance(40);http($c,form($cfg,'Work',0,$now));advance(3);GeoPresence_Timer($c);
    advance(90);actor_fresh();reading('gate','state','movdown',$now);reading('lower','state','open',$now);
    reading('contact','state','unknown',$now);
    http($c,form($cfg,'Home',1,$now));advance(3);GeoPresence_Timer($c);
    finish_arrivals($c);
    is(scalar(grep {/^(?:door|garage) /} @commands),0,'unknown door and closing gate suppressed');
};

subtest 'newest position cancels a queued opening before dispatch' => sub {
    for my $cancel ('Home','Drive','Work') {
        my ($c,$cfg)=fixture();advance(40);http($c,form($cfg,'Work',0,$now));advance(3);GeoPresence_Timer($c);
        advance(90);actor_fresh();http($c,form($cfg,'Home',1,$now));
        advance(1);http($c,form($cfg,$cancel,$cancel eq 'Work'?1:0,$now));advance(3);GeoPresence_Timer($c);
        is(scalar(grep {/^(?:door|garage) /} @commands),0,"new $cancel departure cancels queued opening");
    }
};

subtest 'batch sorting and conflicts do not depend on reception order' => sub {
    for my $reverse (0,1) {
        my ($c,$cfg)=fixture();advance(40);http($c,form($cfg,'Work',0,$now));advance(3);GeoPresence_Timer($c);
        advance(90);actor_fresh();
        my @body=(form($cfg,'Home',1,$now),form($cfg,'Home',0,$now));
        @body=reverse @body if $reverse;
        http($c,$_) for @body;
        http($c,form($cfg,'Drive',1,$now));advance(3);GeoPresence_Timer($c);
        is(scalar(grep {/^(?:door|garage) /} @commands),0,"conflicting Home pair blocks entire batch $reverse");
        like(GeoPresence_Get($c,'GP','explain','Geo.Test','format=json'),qr/conflicting batch/,'conflict diagnosed');
    }
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Work',0);advance(90);
    process($s,$cfg,'Home',1);process($s,$cfg,'Outer',0);
    ok(!$s->{trip},'simultaneous disjoint observations do not rearm');
};

subtest 'older observations from another zone or phone cannot rewind position' => sub {
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Work',0);
    advance(70);process($s,$cfg,'Outer',0);
    my $e=ev('Home',1,$now-10);$e->{received}=$now;
    GP_Process($s,$cfg,$e,$now,$mono);is($s->{phase},'away','older Home cannot replace newer outer exit');
    $e={kind=>'phone_present',time=>$now-5,received=>$now,generation=>$s->{generation},arrival=>1,key=>'older-phone'};
    GP_Process($s,$cfg,$e,$now,$mono);is($s->{phase},'away','older positive cannot replace newer departure');
    is(scalar @{$s->{intents}},0,'no actions from cross-source reorder');
};

subtest 'work role merges overlapping places and waypoint remembers this trip only' => sub {
    my ($c,$cfg)=fixture();
    push @{$cfg->{rules}}, {name=>'workexit',trigger=>'exit',group=>'Work',cooldown=>0,
        action=>'exit',type=>'notify',params=>{message=>'left work'}};
    push @{$cfg->{rules}}, {name=>'place',trigger=>'exit',locations=>['Z.Sternensteg'],afterExit=>'group:Work',cooldown=>0,
        action=>'halfway',type=>'notify',params=>{message=>'halfway'}};
    push @{$cfg->{rule_index}{exit}{'group:Work'}},$cfg->{rules}[-2];
    push @{$cfg->{rule_index}{exit}{'location:Z.Sternensteg'}},$cfg->{rules}[-1];
    my $s=new_state();advance(40);process($s,$cfg,'Work',1);
    is(scalar @{$s->{intents}},1,'first work enter notifies');
    advance(10);process($s,$cfg,'Work2',1);is(scalar @{$s->{intents}},0,'overlap enter has no duplicate role notification');
    advance(10);process($s,$cfg,'Work',0);is(scalar @{$s->{intents}},0,'still in another work zone');
    advance(10);process($s,$cfg,'Work2',0);is(scalar @{$s->{intents}},1,'last work exit notifies');
    advance(70);process($s,$cfg,'Sternensteg',0);is(scalar @{$s->{intents}},1,'waypoint after work exit notifies');
    advance(10);process($s,$cfg,'Sternensteg',0);is(scalar @{$s->{intents}},0,'waypoint once per return');
    advance(10);arrive($s,$cfg);advance(100);process($s,$cfg,'Sternensteg',0);
    is(scalar @{$s->{intents}},0,'past trip work context not reused');
};

subtest 'source health, TTL, complete negative coverage and post-start timestamps' => sub {
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Home',0);
    my $v=negative_samples();$v->{p2}{healthy}=0;
    GP_Phone($s,$cfg,$v,$now,$mono);advance(180);
    $v=negative_samples();$v->{p2}{healthy}=0;GP_Phone($s,$cfg,$v,$now,$mono);
    ok(!$s->{trip}{armed},'scanner failure cannot stand for negative sample');
    $v=negative_samples();$v->{p3}{value}='present';GP_Phone($s,$cfg,$v,$now,$mono);
    is($s->{phone}{state},'present','one positive wins over two negatives');
    $s=new_state();$v=negative_samples();GP_Phone($s,$cfg,$v,$now,$mono);
    is($s->{phone}{state},'unknown','saved readings at start not treated as new');
    advance(40);reading('p1','presence','absent',$now);reading('p1','state','disconnected',$now);
    my $samples=GP_PhoneSamples($cfg,$now);ok(!$samples->{p1}{healthy},'disconnected proxy unhealthy');
    $defs{p2}{INTERVAL_NORMAL}=120;
    is(GP_PhoneSamples($cfg,$now)->{p2}{ttl},270,'TTL tracks scan interval');
};

subtest 'rapid return, long absence, motion expiry and abandoned approach' => sub {
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Drive',0);advance(59);arrive($s,$cfg,'automotive');
    is(scalar @{$s->{intents}},0,'rapid return deliberately does not open');
    $s=new_state();advance(40);process($s,$cfg,'Work',0);advance(3*86400);
    GP_TickState($s,$cfg,$now,$mono);arrive($s,$cfg);
    is(scalar @{$s->{intents}},2,'multi-day departure remains valid in same session');
    $s=new_state();advance(40);process($s,$cfg,'Drive',0);advance(90);process($s,$cfg,'Drive',1,'automotive');
    advance(10);arrive($s,$cfg,'walking');
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open','garage_open'],'recent drive survives walking after parking until confirmed arrival');
    $s=new_state();advance(40);process($s,$cfg,'Drive',0);advance(90);process($s,$cfg,'Drive',1,'automotive');
    advance(601);GP_TickState($s,$cfg,$now,$mono);
    is($s->{phase},'away','approach times out without arrival');ok($s->{trip}{armed},'trip survives abandoned approach');
    ok(!GP_VehicleEligible($s,$cfg,$now),'old motion does not qualify new approach');
};

subtest 'clock discontinuity also revokes permissions without a webhook' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);advance(40);process($s,$cfg,'Work',0);
    my $generation=$s->{generation};my $phone=\&GP_Phone;my $revoked_before_phone;
    {
        no warnings 'redefine';
        local *GP_Phone=sub {
            $revoked_before_phone=!$_[0]{trip} && $_[0]{generation} ne $generation;
            return $phone->(@_);
        };
        $now+=3600;GeoPresence_Timer($c);
    }
    ok($revoked_before_phone,'clock revocation precedes phone processing');
    ok(!$s->{trip},'timer revokes permissions after wall-clock jump');
    advance(40);arrive($s,$cfg);is(scalar @{$s->{intents}},0,'arrival after clock repair has no old permission');
};

subtest 'geometry changes are adopted and old retries cannot restore the previous geometry' => sub {
    my ($c,$cfg)=fixture();advance(40);
    http($c,form($cfg,'Work',0,$now));advance(3);GeoPresence_Timer($c);
    ok(GP_State($c,'Geo.Test',0)->{trip}{armed},'departure armed before change');
    my $old=form($cfg,'Work',0,$now);advance(1);
    is((http($c,form($cfg,'Work',0,$now,latitude=>1)))[0],200,'new geometry accepted');
    advance(3);GeoPresence_Timer($c);
    is(GP_Config($c,'Geo.Test')->{zones}{'Z.Work'}{lat},1,'geometry adopted');
    ok(!GP_State($c,'Geo.Test',0)->{trip},'change revokes old trip without arming a new one');
    http($c,$old);advance(3);GeoPresence_Timer($c);
    is(GP_Config($c,'Geo.Test')->{zones}{'Z.Work'}{lat},1,'old retry cannot roll back geometry');
    my $record=GP_Read('Z.Work','gp_geometry','');
    is(JSON::PP::decode_json($record)->{lat},1,'metadata uses ordinary FHEM readings');
    GP_ResetController($c);GeoPresence_Timer($c);
    is(GP_Config($c,'Geo.Test')->{zones}{'Z.Work'}{lat},1,'reload restores metadata');
    ok(!GP_State($c,'Geo.Test',0)->{trip},'reload restores no permission');
};

subtest 'active configuration validation and invalid references have no side effects' => sub {
    my ($c,$cfg)=fixture();my @before=sort keys %defs;
    local $attr{'R.Door'}{action}='missing';
    config_event('ATTR R.Door action missing');
    like(join(' ',GP_Validate($c,'Geo.Test',1)),qr/action missing/,'unknown action explained');
    is_deeply([sort keys %defs],\@before,'validation never creates a missing device');
    like(GeoPresence_Attr('set','Z.Home','radius',60),qr/received from Geofency/,'manual geometry is not configuration');
    device('People.Loc.Test','notify');
    like(join(' ',GP_Validate($c,'Geo.Test',1)),qr/disable legacy/,'legacy action must be disabled');
    $attr{rr_Test}{rr_geofenceUUIDs}='DEVICE';
    config_event('ATTR rr_Test rr_geofenceUUIDs DEVICE');
    like(join(' ',GP_Validate($c,'Geo.Test',1)),qr/remove rr_geofenceUUIDs/,'old input binding must be removed');
};

subtest 'disabled rules and duplicate rules do not add hidden actions' => sub {
    my ($c,$cfg)=fixture();$attr{'R.Early'}{enabled}=0;$attr{'R.Late'}{enabled}=0;
    config_event('ATTR R.Late enabled 0');
    $cfg=GP_Config($c,'Geo.Test');my $s=new_state();advance(40);process($s,$cfg,'Work',0);advance(90);arrive($s,$cfg);
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'no hidden garage rule');
    my ($door)=grep {$_->{type} eq 'door_open'} @{$cfg->{rules}};
    push @{$cfg->{rules}}, {%$door,name=>'anotherRule'};
    push @{$cfg->{rule_index}{arrival}{arrival}},$cfg->{rules}[-1];
    $s=new_state();advance(40);process($s,$cfg,'Work',0);advance(90);arrive($s,$cfg);
    is(scalar @{$s->{intents}},1,'same actor deduplicated independently of rule name');
};

subtest 'shared actuator reservations and independent later arrivals' => sub {
    my ($c,$cfg,$cfg2)=shared_actor_fixture();
    my $s1=GP_State($c,'Geo.Test',0);my $s2=GP_State($c,'Geo.Other',0);
    advance(40);process($s1,$cfg,'Work',0);process($s2,$cfg2,'Work',0);advance(90);actor_fresh();
    arrive($s1,$cfg);arrive($s2,$cfg2);
    GP_Dispatch($c,'Geo.Test',$cfg,$s1,0,$now,$mono);GP_Dispatch($c,'Geo.Other',$cfg2,$s2,0,$now,$mono);
    is(scalar(grep {$_ eq 'door lock unlocked'} @commands),1,'two residents share one pending door action');
    is(scalar(grep {$_ eq 'garage on'} @commands),1,'two residents share one pending garage action');
    advance(1);reading('feedback','pulse_state','confirmed',$now);GP_ActorFeedback($c,$now,$mono);
    is($s2->{door_result},'confirmed','feedback reaches the second resident');
    advance(40);process($s2,$cfg2,'Drive',0);advance(90);actor_fresh();arrive($s2,$cfg2);
    GP_Dispatch($c,'Geo.Other',$cfg2,$s2,0,$now,$mono);
    is(scalar(grep {$_ eq 'door lock unlocked'} @commands),2,'later independent arrival can reopen closed door');
};

subtest 'fractional actor starts accept new feedback in the same FHEM second' => sub {
    for my $terminal (qw(confirmed failed cancelled)) {
        my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
        advance(40);process($s,$cfg,'Work',0);advance(90.2);actor_fresh();
        arrive($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        advance(0.5);reading('feedback','pulse_state',$terminal,$now);
        GP_ActorFeedback($c,$now,$mono);
        is($s->{door_result},$terminal,"same-second $terminal completes the door request");
        ok(!$c->{helper}{gp}{actors}{door},"$terminal releases the door reservation");
        reading('gate','state','on',$now);reading('upper','state','closed',$now);reading('lower','state','open',$now);
        GP_ActorFeedback($c,$now,$mono);
        is($s->{garage_result},'confirmed','same-second garage end positions confirm the request');
        ok(!$c->{helper}{gp}{actors}{garage},'garage reservation released');
    }
};

subtest 'unchanged old feedback is not a new confirmation, even in the same second' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Work',0);advance(90.2);actor_fresh();
    reading('feedback','pulse_state','confirmed',$now);
    arrive($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    GP_ActorFeedback($c,$now,$mono);
    is($s->{door_result},'pending','old same-second terminal state does not complete a new command');
    actor_event($c,'feedback','unrelated','confirmed');GP_ActorFeedback($c,$now,$mono);
    is($s->{door_result},'pending','unrelated feedback-device event cannot refresh pulse_state');
    advance(0.2);actor_event($c,'feedback','pulse_state','confirmed',$now-1);
    GP_ActorFeedback($c,$now,$mono);
    is($s->{door_result},'pending','event carrying a reading from an earlier second is rejected');
    advance(0.3);actor_event($c,'feedback','pulse_state','confirmed');
    GP_ActorFeedback($c,$now,$mono);
    is($s->{door_result},'confirmed','new matching event disambiguates identical value and second');
    ok(!$c->{helper}{gp}{actors}{door},'valid repeated terminal value frees the actor');
};

subtest 'synchronous same-second feedback frees a shared actor for the next resident' => sub {
    my ($c,$cfg,$cfg2)=shared_actor_fixture();
    my $s1=GP_State($c,'Geo.Test',0);my $s2=GP_State($c,'Geo.Other',0);
    advance(40);process($s1,$cfg,'Work',0);process($s2,$cfg2,'Work',0);advance(90.2);actor_fresh();
    reading('feedback','pulse_state','confirmed',$now);
    $on_command=sub {
        return unless $_[0] eq 'door lock unlocked';
        actor_event($c,'feedback','pulse_state','pending');
        actor_event($c,'feedback','pulse_state','confirmed');
    };
    arrive($s1,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s1,0,$now,$mono);
    GP_ActorFeedback($c,$now,$mono);
    is($s1->{door_result},'confirmed','feedback inside CommandSet is retained before the first poll');
    advance(0.5);arrive($s2,$cfg2);GP_Dispatch($c,'Geo.Other',$cfg2,$s2,0,$now,$mono);
    is(scalar(grep {$_ eq 'door lock unlocked'} @commands),2,'later resident gets an independent door pulse');
    GP_ActorFeedback($c,$now,$mono);
    is($s2->{door_result},'confirmed','second pulse is confirmed independently');
};

subtest 'door terminal events survive idle before polling and do not leak to the next pulse' => sub {
    for my $terminal (qw(confirmed failed cancelled)) {
        my ($c,$cfg,$cfg2)=shared_actor_fixture();
        my $s1=GP_State($c,'Geo.Test',0);my $s2=GP_State($c,'Geo.Other',0);
        advance(40);process($s1,$cfg,'Work',0);process($s2,$cfg2,'Work',0);advance(90.2);actor_fresh();
        arrive($s1,$cfg);arrive($s2,$cfg2);
        GP_Dispatch($c,'Geo.Test',$cfg,$s1,0,$now,$mono);GP_Dispatch($c,'Geo.Other',$cfg2,$s2,0,$now,$mono);
        advance(0.1);actor_event($c,'feedback','pulse_state',$terminal);
        advance(0.1);actor_event($c,'feedback','pulse_state','idle');
        is(GP_Read('feedback','pulse_state',''),'idle','contact close resets visible pulse_state before the poll');
        GP_ActorFeedback($c,$now,$mono);
        is($s1->{door_result},$terminal,"first resident keeps $terminal despite idle");
        is($s2->{door_result},$terminal,"shared resident receives $terminal despite idle");
        ok(!$c->{helper}{gp}{actors}{door},'completed door reservation is released');
        advance(1);process($s2,$cfg2,'Work',0);advance(61);actor_fresh();arrive($s2,$cfg2);
        GP_Dispatch($c,'Geo.Other',$cfg2,$s2,0,$now,$mono);
        is(scalar(grep {$_ eq 'door lock unlocked'} @commands),2,'next independent arrival receives its own pulse');
        GP_ActorFeedback($c,$now,$mono);
        is($s2->{door_result},'pending','previous completion is never inherited by a new reservation');
    }
};

subtest 'synchronous completion survives idle and later diagnostics before the timer' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Work',0);advance(90.2);actor_fresh();
    $on_command=sub {
        return unless $_[0] eq 'door lock unlocked';
        actor_event($c,'feedback','pulse_state','pending');
        actor_event($c,'feedback','pulse_state','confirmed');
        actor_event($c,'feedback','pulse_state','idle');
        actor_event($c,'feedback','pulse_state','failed');
        actor_event($c,'feedback','pulse_state','idle');
    };
    arrive($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    advance(61);GP_ActorFeedback($c,$now,$mono);
    is($s->{door_result},'confirmed','first validated terminal result survives later states and a delayed poll');
    ok(!$c->{helper}{gp}{actors}{door},'synchronous completion releases reservation without timeout');
};

subtest 'an arrival after observed completion cannot share the already finished pulse' => sub {
    my ($c,$cfg,$cfg2)=shared_actor_fixture();
    my $s1=GP_State($c,'Geo.Test',0);my $s2=GP_State($c,'Geo.Other',0);
    advance(40);process($s1,$cfg,'Work',0);process($s2,$cfg2,'Work',0);advance(90.2);actor_fresh();
    arrive($s1,$cfg);arrive($s2,$cfg2);
    $on_command=sub {
        return unless $_[0] eq 'door lock unlocked';
        actor_event($c,'feedback','pulse_state','confirmed');
        actor_event($c,'feedback','pulse_state','idle');
    };
    GP_Dispatch($c,'Geo.Test',$cfg,$s1,0,$now,$mono);
    GP_Dispatch($c,'Geo.Other',$cfg2,$s2,0,$now,$mono);
    is(scalar(grep {$_ eq 'door lock unlocked'} @commands),2,'next resident gets a new pulse even before the next feedback timer');
    is($s1->{door_result},'confirmed','finished request is finalized before reserving the next pulse');
    GP_ActorFeedback($c,$now,$mono);
    is($s2->{door_result},'confirmed','next resident receives the result of their own pulse');
};

subtest 'consistent garage completion survives another contact change before polling' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Work',0);advance(90.2);actor_fresh();
    arrive($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    actor_event($c,'gate','state','on');actor_event($c,'upper','state','closed');
    GP_ActorFeedback($c,$now,$mono);
    is($s->{garage_result},'pending','inconsistent intermediate end positions cannot complete the request');
    actor_event($c,'lower','state','open');
    actor_event($c,'gate','state','movdown');actor_event($c,'upper','state','open');
    GP_ActorFeedback($c,$now,$mono);
    is($s->{garage_result},'confirmed','observed consistent open state survives subsequent closing movement');
    ok(!$c->{helper}{gp}{actors}{garage},'completed garage reservation releases independently of later position');
};

subtest 'stale terminal event followed by idle cannot complete a new pulse' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Work',0);advance(90.2);actor_fresh();
    arrive($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    actor_event($c,'feedback','pulse_state','confirmed',$now-1);
    actor_event($c,'feedback','pulse_state','idle');
    GP_ActorFeedback($c,$now,$mono);
    is($s->{door_result},'pending','idle cannot make the earlier stale confirmation current');
    advance(61);GP_ActorFeedback($c,$now,$mono);
    is($s->{door_result},'uncertain','without valid completion the timeout still applies');
};

subtest 'observing same-second feedback after a debug switch remains passive' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Work',0);advance(90.2);actor_fresh();
    arrive($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    mode('GP','debug');
    my ($calls,$commands,$messages)=($reading_calls,scalar @commands,scalar @messages);
    advance(0.5);actor_event($c,'feedback','pulse_state','confirmed');
    # A reload-style reset keeps observation of already dispatched hardware.
    GP_ResetController($c);
    actor_event($c,'feedback','pulse_state','idle');
    actor_event($c,'gate','state','on');actor_event($c,'upper','state','closed');actor_event($c,'lower','state','open');
    GP_ActorFeedback($c,$now,$mono);
    is(scalar(keys %{$c->{helper}{gp}{actors}}),0,'mode switch retains observation until old hardware requests finish');
    is($reading_calls,$calls,'passive feedback makes no readings API calls in debug');
    is(scalar @commands,$commands,'passive feedback issues no commands in debug');
    is(scalar @messages,$messages,'passive feedback sends no messages in debug');
};

subtest 'uncertain dispatch does not retry and mode changes stop reentrant output' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);advance(40);process($s,$cfg,'Work',0);advance(90);actor_fresh();
    arrive($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    advance(61);GP_ActorFeedback($c,$now,$mono);
    is($s->{door_result},'uncertain','missing acknowledgement reported uncertain');
    is(scalar(grep {$_ eq 'door lock unlocked'} @commands),1,'timeout never resends command');
    ($c,$cfg)=fixture();$s=GP_State($c,'Geo.Test',0);advance(40);process($s,$cfg,'Work',0);advance(90);actor_fresh();arrive($s,$cfg);
    $on_command=sub { mode('GP','debug'); };
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is(scalar @commands,1,'mode changed by synchronous callback stops remaining commands');
    my $view=JSON::PP::decode_json(GeoPresence_Get($c,'GP','explain','Geo.Test','debug','format=json'));
    is($view->{debug_ready},0,'debug waits for already issued hardware request');
    advance(61);GeoPresence_Timer($c);
    $view=JSON::PP::decode_json(GeoPresence_Get($c,'GP','explain','Geo.Test','debug','format=json'));
    is($view->{debug_ready},1,'after feedback timeout debug is ready');
};

subtest 'real actor completions stay logged after controller and resident session changes' => sub {
    for my $kind ('door_open','garage_open') {
        for my $change (['GP','mode','debug'],['GP','mode','disabled'],['Geo.Test','mode','debug'],['reload']) {
            for my $timeout (0,1) {
                my ($c,$cfg)=fixture();advance(40);actor_fresh();$attr{GP}{verbose}=3;
                my $s=GP_State($c,'Geo.Test',0);$s->{phase}='home';
                my $door=$kind eq 'door_open';my $target=$door ? 'door':'garage';
                my $params=$door ? {target=>$target,command=>'lock unlocked',contact=>'contact',feedbackDevice=>'feedback'}
                    : {target=>$target,command=>'on',stateDevice=>'gate',upperContact=>'upper',lowerContact=>'lower'};
                $s->{intents}=[output_intent($s,$cfg,$kind,$params)];
                GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
                is(scalar(grep {$_->[2] =~ /requested/} @logs),1,'real request logged before another callback');
                $change->[0] eq 'reload' ? GP_ResetController($c) : mode($change->[0],$change->[2]);
                ok(exists $c->{helper}{gp}{actors}{$target},'hardware reservation survives state reset');
                my ($calls,$commands,$messages)=($reading_calls,scalar @commands,scalar @messages);
                advance($timeout ? 61:1);
                if (!$timeout) {
                    if ($door) {actor_event($c,'feedback','pulse_state','confirmed');}
                    else {
                        actor_event($c,'gate','state','on');actor_event($c,'upper','state','closed');actor_event($c,'lower','state','open');
                    }
                }
                GP_ActorFeedback($c,$now,$mono);GP_ActorFeedback($c,$now,$mono);
                my $match=$timeout ? qr/ended without confirmation/ : $door ? qr/confirmed the opening pulse/ : qr/is open/;
                is(scalar(grep {$_->[2] =~ $match} @logs),1,'actual completion or timeout logged exactly once');
                ok(!exists $c->{helper}{gp}{actors}{$target},'completed reservation removed');
                ok(!exists $c->{helper}{gp}{prod}{'Geo.Test'},'logging does not recreate deleted productive state');
                is_deeply([$reading_calls,scalar @commands,scalar @messages],[$calls,$commands,$messages],
                    'retained feedback is passive and never replays an output');
            }
        }
    }
};

subtest 'actual output records survive synchronous mode changes inside adapters' => sub {
    for my $kind ('door_open','garage_open','switch_on','notify') {
        my ($c,$cfg)=fixture();advance(40);actor_fresh();$attr{GP}{verbose}=3;
        device('lamp','dummy');
        my %params=(door_open=>{target=>'door',command=>'lock unlocked',contact=>'contact',feedbackDevice=>'feedback'},
            garage_open=>{target=>'garage',command=>'on',stateDevice=>'gate',upperContact=>'upper',lowerContact=>'lower'},
            switch_on=>{target=>'lamp',command=>'on'},notify=>{message=>'Test angekommen',channel=>0});
        $on_command=sub {mode('GP','debug')};
        $on_message=sub {mode('GP','debug')};
        my $dispatch=\&GP_Dispatch;
        {
            no warnings 'redefine';
            local *GP_Dispatch=sub {
                my ($controller,$resident,$config,$state,$debug)=@_;
                unless ($debug) {
                    $state->{phase}='home';
                    $state->{intents}=[map {{%{output_intent($state,$config,$kind,$params{$kind})},rule=>'actual-output'}} 1..2];
                }
                return $dispatch->(@_);
            };
            GeoPresence_Timer($c);
        }
        is(scalar(@commands)+scalar(@messages),1,'mode-changing first output blocks the second request');
        is(GP_Mode('GP'),'debug','adapter callback changed mode');
        my $match=$kind eq 'notify' ? qr/Notification handed to/ : qr/requested/;
        is(scalar(grep {$_->[2] =~ $match} @logs),1,'executed action remains logged despite early timer exit');
        GeoPresence_Timer($c);
        is(scalar(grep {$_->[2] =~ $match} @logs),1,'new debug timer does not duplicate the real output');
    }
};

subtest 'logging callbacks cannot duplicate completion or authorize a further command' => sub {
    my ($c,$cfg)=fixture();advance(40);actor_fresh();$attr{GP}{verbose}=3;
    my $s=GP_State($c,'Geo.Test',0);$s->{phase}='home';
    my $intent=output_intent($s,$cfg,'door_open',
        {target=>'door',command=>'lock unlocked',contact=>'contact',feedbackDevice=>'feedback'});
    $s->{intents}=[{%$intent}];GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    advance(1);actor_event($c,'feedback','pulse_state','confirmed');
    $s->{intents}=[{%$intent}];
    $on_log=sub {
        return unless $_[2] =~ /confirmed the opening pulse/;
        GP_ActorFeedback($c,$now,$mono);
        mode('GP','debug');
    };
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is(scalar(grep {$_->[2] =~ /confirmed the opening pulse/} @logs),1,'completion detached before reentrant logger callback');
    is(scalar @commands,1,'mode changed by logging callback blocks the next physical command');
    is(scalar keys %{$c->{helper}{gp}{actors}},0,'reentry leaves no phantom reservation');
};

subtest 'manual roommate changes and stale saved readings never authorize actions' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);advance(40);process($s,$cfg,'Work',0);
    $defs{rr_Test}{CHANGED}=['gone'];GeoPresence_Notify($c,$defs{rr_Test});ok($s->{trip}{armed},'autoGone does not create or erase geo history');
    $defs{rr_Test}{CHANGED}=['home'];GeoPresence_Notify($c,$defs{rr_Test});ok(!$s->{trip},'manual home consumes pending trip');
    advance(90);arrive($s,$cfg);is(scalar @{$s->{intents}},0,'manual home did not arm');
    reading('Geo.Test','gp_arrival_armed',1,$now);reading('Geo.Test','gp_door_result','pending',$now);
    http($c,form($cfg,'Work',0,$now));
    GP_ResetController($c);GeoPresence_Timer($c);advance(40);http($c,form($cfg,'Home',1,$now));advance(3);GeoPresence_Timer($c);
    is(scalar(grep {/^(?:door|garage) /} @commands),0,'saved armed state and accepted queue cannot resume after restart');
    is(GP_Read('Geo.Test','gp_arrival_armed',9),0,'snapshot replaced with unarmed current state');
};

subtest 'debug simulation, reads and activation cannot affect production' => sub {
    my ($c,$cfg)=fixture();mode('GP','debug');GeoPresence_Timer($c);
    my $before=$reading_calls;my $snapshot=JSON::PP->new->canonical->encode($defs{rr_Test}{READINGS});
    GeoPresence_Set($c,'GP','debugReset','Geo.Test');
    GeoPresence_Set($c,'GP','debugPhoneMode','Geo.Test','simulated');
    GeoPresence_Set($c,'GP','debugPhone','Geo.Test','absent');advance(40);
    http($c,form($cfg,'Home',0,$now),1);advance(3);GeoPresence_Timer($c);
    # New virtual measurements accompany each advance, without editing real proxies.
    for (1..37) {advance(5);GeoPresence_Timer($c);}
    GeoPresence_Set($c,'GP','debugPhone','Geo.Test','present');advance(5);GeoPresence_Timer($c);
    like(GeoPresence_Get($c,'GP','debugTrace','Geo.Test','format=json'),qr/would execute/,'simulated short walk reports intended door action');
    GeoPresence_Get($c,'GP','explain','Geo.Test','debug','format=json');GeoPresence_Get($c,'GP','explain','Geo.Test','format=json');
    is($reading_calls,$before,'debug invokes no reading API, including userReadings entry point');
    is(JSON::PP->new->canonical->encode($defs{rr_Test}{READINGS}),$snapshot,'ROOMMATE snapshot untouched');
    is(scalar @commands,0,'debug has no commands');is(scalar @messages,0,'debug has no notifications');
    is_deeply($defs{p1}{READINGS},{},'real proxy untouched');
    mode('GP','active');GeoPresence_Timer($c);advance(40);
    http($c,form($cfg,'Home',1,$now));advance(3);GeoPresence_Timer($c);
    is(scalar(grep {/^(?:door|garage) /} @commands),0,'activation does not import simulated trip');
};

subtest 'controller rename repairs definitions and replaces its listener session' => sub {
    my %module;{local %defs;GeoPresence_Initialize(\%module);}
    is($module{RenameFn},'GeoPresence_Rename','FHEM rename callback is registered');
    for my $cold (0,1) {
        my ($c,$cfg)=fixture();advance(40);actor_fresh();
        my $s=GP_State($c,'Geo.Test',0);$s->{phase}='home';
        my $intent=output_intent($s,$cfg,'door_open',
            {target=>'door',command=>'lock unlocked',contact=>'contact',feedbackDevice=>'feedback'});
        $s->{intents}=[$intent];GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        my $actor=$c->{helper}{gp}{actors}{door};ok($actor,'hardware reservation exists before rename');
        my $old_rt=$c->{helper}{gp};$s->{intents}=[{%$intent}];
        GP_InvalidateDevices($c) if $cold;
        rename_device('GP','GP.Renamed');
        ok($c->{helper}{gp_devices},'global notification retains the inventory already refreshed by RenameFn');
        is($c->{CONTROLLER},'GP.Renamed','controller owns its new name');
        is($defs{'Geo.Test'}{DEF},'resident GP.Renamed rr_Test','resident saved definition uses the new controller');
        is($defs{'A.Door'}{DEF},'action GP.Renamed door_open','action saved definition uses the new controller');
        is($defs{'R.Door'}{DEF},'rule GP.Renamed','rule saved definition uses the new controller');
        is($defs{'Z.Home'}{PARENT},'Geo.Test','location retains its resident parent');
        ok(!exists $c->{helper}{gp_http},'old listener is closed before the callback returns');
        ok(!GP_TimerCurrent($c,$old_rt),'old timer session cannot issue later outputs');
        is($c->{helper}{gp}{actors}{door},$actor,'already dispatched operation stays observed');
        GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        is(scalar @commands,1,'a plan extracted from the old context is not repeated');
        GeoPresence_Timer($c);
        ok($c->{helper}{gp}{ready},'new controller session opens the listener');
        is((http($c,form($cfg,'Home',1,$now)))[0],200,'webhooks remain available under the renamed controller');
        advance(1);actor_event($c,'feedback','pulse_state','confirmed');GP_ActorFeedback($c,$now,$mono);
        ok(!exists $c->{helper}{gp}{actors}{door},'the existing operation can still complete');
    }
};

subtest 'resident rename preserves credentials and quota while revoking affected journeys' => sub {
    for my $shared (0,1) {
        my ($c)=shared_actor_fixture();advance(40);
        unless ($shared) {
            $attr{$_}{residents}='Geo.Test' for qw(R.Door R.Late R.Work);
            GP_InvalidateDevices($c);
        }
        my $cfg=GP_Config($c,'Geo.Test');my $other_cfg=GP_Config($c,'Geo.Other');
        my $s=GP_State($c,'Geo.Test',0);my $other=GP_State($c,'Geo.Other',0);
        my $listener=$c->{helper}{gp_http};my $secret=$keys{'GeoPresence_Geo.Test_auth'};
        GP_Auth('Geo.Test');$keys{'GeoPresence_Geo.New_auth'}='stale';GP_Auth('Geo.New');
        for (1..120) {http($c,'isTest=invalid');}
        $c->{helper}{gp}{learned}{'Geo.Test'}={confirmed=>1,device=>'device',zones=>{}};
        $c->{helper}{gp}{actors}{door}={waiters=>{'Geo.Test'=>1}};
        rename_device('Geo.Test','Geo.New');
        is($keys{GP_AuthKey('Geo.New')},$secret,'existing password verifier moved to the new safe key');
        ok(!exists $keys{'GeoPresence_Geo.Test_auth'},'old key was removed');
        ok(!exists $keys{GP_AuthKey('Geo.Test')} && !exists $keys{'GeoPresence_Geo.New_auth'},'obsolete canonical and legacy entries were removed');
        is((GP_Auth('Geo.New'))[1],$secret,'cached credentials cannot select the stale destination key');
        is($defs{'Z.Home'}{PARENT},'Geo.New','private location parent follows the resident');
        is($defs{'Z.Home'}{DEF},'location Geo.New home','private location definition remains restartable');
        is($c->{helper}{gp_http},$listener,'resident rename does not restart the shared listener');
        ok(!exists $c->{helper}{gp}{prod}{'Geo.Test'},'old resident state was discarded');
        ok(!exists $c->{helper}{gp}{resident_generation}{'Geo.Test'},'old generation metadata was removed');
        ok($c->{helper}{gp}{learned}{'Geo.New'}{confirmed},'confirmed setup metadata is retained');
        ok($c->{helper}{gp}{actors}{door}{waiters}{'Geo.New'},'pending actor feedback follows the resident name');
        ok(!exists $c->{helper}{gp}{actors}{door}{waiters}{'Geo.Test'},'actor has no stale waiter name');
        is((http($c,'isTest=invalid'))[0],429,'rename cannot renew the person quota');
        is($attr{'R.Door'}{residents},'Geo.Test'.($shared?',Geo.Other':''),'public rule selector is not silently rewritten');
        like(join('; ',GP_Validate($c)),qr/unknown resident Geo\.Test/,'stale public reference is visible in validation');
        if ($shared) {ok(!exists $c->{helper}{gp}{prod}{'Geo.Other'},'shared rule loses every affected pending context');}
        else {is($c->{helper}{gp}{prod}{'Geo.Other'},$other,'unrelated resident context is retained');}
    }
};

subtest 'regex-shaped resident names preserve migrated and unrelated logins' => sub {
    my ($c)=shared_actor_fixture();mode('GP','debug');
    rename_device('Geo.Test','Geo.A');rename_device('Geo.Other','Geo-A');
    my $other_password='other_password_0123456789';
    like(GeoPresence_Set($defs{'Geo-A'},'Geo-A','webhookPassword',$other_password),qr/password stored/i,'unrelated person has a distinct password');
    my $other_auth='Basic '.encode_base64('other-user:'.$other_password,'');
    $keys{'GeoPresence_GeoBA_auth'}='unrelated legacy value';
    for my $pair (['Geo.A','GeoXA'],['GeoXA','Geo.A']) {
        rename_device(@$pair);GP_ResetController($c);GeoPresence_Timer($c);
        is((http($c,'isTest=invalid'))[0],400,"@$pair: migrated login still authenticates after cache reset");
        is((http($c,'isTest=invalid',undef,$other_auth))[0],400,'similar name keeps its independent login');
        is($keys{'GeoPresence_GeoBA_auth'},'unrelated legacy value','another matching legacy name was not deleted');
    }
};

subtest 'legacy access is exact and new password operations preserve other people' => sub {
    my ($c)=fixture();mode('GP','debug');
    my $old=$keys{'GeoPresence_Geo.Test_auth'};
    $keys{'GeoPresence_Geo-Test_auth'}='foreign legacy verifier';
    GP_ResetController($c);GeoPresence_Timer($c);
    is((GP_Auth('Geo.Test'))[1],$old,'legacy lookup uses the exact name even when a similar key sorts first');
    ok(!exists $keys{GP_AuthKey('Geo.Test')},'reading an old verifier does not rewrite the key store');
    my $password='replacement_password_0123456789';
    like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','webhookPassword',$password),qr/password stored/i,'new password uses safe storage');
    my $new=$keys{GP_AuthKey('Geo.Test')};
    isnt($new,$old,'new password replaced the verifier');
    is((GP_Auth('Geo.Test'))[1],$new,'new password invalidates the cached old verifier');
    ok(!exists $keys{'GeoPresence_Geo.Test_auth'},'writing removes only the exact obsolete entry');
    is($keys{'GeoPresence_Geo-Test_auth'},'foreign legacy verifier','password change preserves the similar legacy name');
    $keys{'GeoPresence_Geo.Test_auth'}=$old;
    $keys{GP_AuthKey('Geo.Test')}='';
    is((GP_ReadAuth('Geo.Test'))[1],'','an existing canonical entry cannot fall back to an obsolete password');
    my $other_key=GP_AuthKey('Geo-Test');$keys{$other_key}='foreign canonical verifier';
    is(GeoPresence_Delete($defs{'Geo.Test'}),undef,'deleting a person removes both of their key formats');
    ok(!exists $keys{'GeoPresence_Geo.Test_auth'} && !exists $keys{GP_AuthKey('Geo.Test')},'both exact entries were deleted');
    is($keys{'GeoPresence_Geo-Test_auth'},'foreign legacy verifier','delete preserves the similar legacy name');
    is($keys{$other_key},'foreign canonical verifier','delete preserves the other canonical key');
};

subtest 'one read preserves exact lookup, format precedence and first duplicate' => sub {
    fixture();
    my $old='GeoPresence_Geo.Test_auth:';my $new=GP_AuthKey('Geo.Test').':';
    $attr{global}{modpath}='/configured/fhem';$attr{global}{keyFileName}='task..keys';
    for my $case (
        [[$old.'first'],'first'], [[$new.'new'],'new'],
        [[$old.'old',$new.'new'],'new'], [[$new.'new',$old.'old'],'new'],
        [[$old.'first',$old.'second'],'first'], [[$old.'',$old.'second'],''],
        [[$old.'old',$new.'',$new.'new'],''], [[$new.'invalid',$new.'new',$old.'old'],'invalid'],
        [['GeoPresence_Geo-Test_auth:foreign'],undef], [[],undef]) {
        my @reads;
        no warnings 'redefine';
        local *FileRead=sub {push @reads,$_[0];return (undef,@{$case->[0]});};
        local *FileWrite=sub {die 'Reading credentials must not write the key store';};
        is_deeply([GP_ReadAuth('Geo.Test')],[undef,$case->[1]],'selection preserves the stored value and precedence');
        is_deeply(\@reads,['/configured/fhem/FHEM/FhemUtils/taskkeys'],'exactly one read uses the configured FHEM key path');
    }
    {
        no warnings 'redefine';
        local *FileRead=sub {return ('store unavailable',undef);};
        is_deeply([GP_ReadAuth('Geo.Test')],['store unavailable',undef],'file errors are returned without an alternate lookup');
    }
};

subtest 'partial storage failure cannot retain a stale authentication cache' => sub {
    my ($c)=fixture();mode('GP','debug');
    my $old=(GP_Auth('Geo.Test'))[1];
    {
        no warnings 'redefine';
        local *FileWrite=sub {return 'legacy cleanup failed';};
        is(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','webhookPassword','replacement_password_0123456789'),
            'legacy cleanup failed','cleanup failure is reported after the new verifier was written');
    }
    isnt((GP_Auth('Geo.Test'))[1],$old,'next authentication reloads the written canonical verifier');
    is((GP_Auth('Geo.Test'))[1],$keys{GP_AuthKey('Geo.Test')},'cached state agrees with the store after partial failure');
};

subtest 'renamed locations, actions and rules revoke their affected contexts' => sub {
    for my $name ('Z.Home','A.Door','R.Door') {
        my ($c,$cfg)=fixture();advance(40);my $s=GP_State($c,'Geo.Test',0);
        my $listener=$c->{helper}{gp_http};GP_InvalidateDevices($c);
        rename_device($name,$name.'.New');
        ok(!exists $c->{helper}{gp}{prod}{'Geo.Test'},"$name: affected context was revoked with a cold catalogue");
        is($c->{helper}{gp_http},$listener,"$name: unrelated listener remains open");
    }
    my ($c)=fixture();rename_device('Geo.Test','9.Invalid');
    like(join('; ',GP_Validate($c)),qr/invalid GeoPresence device name/,'FHEM-permitted names outside the module contract remain visibly invalid');
};

subtest 'credential migration failures stay disabled across session reset' => sub {
    for my $fault ('read','write','delete','legacy delete') {
        my ($c)=fixture();my $set=\&setKeyValue;
        my $read=\&FileRead;my $write=\&FileWrite;
        $keys{'GeoPresence_Geo.New_auth'}='stale';GP_Auth('Geo.New');
        {
            no warnings 'redefine';
            local *setKeyValue=sub {return 'write failure' if ($fault eq 'write' && $_[0] eq GP_AuthKey('Geo.New'))
                || ($fault eq 'delete' && $_[0] eq GP_AuthKey('Geo.Test'));return $set->(@_);};
            local *FileRead=sub {return ('read failure',undef) if $fault eq 'read';return $read->(@_);};
            local *FileWrite=sub {return 'write failure' if $fault eq 'legacy delete';return $write->(@_);};
            rename_device('Geo.Test','Geo.New');
        }
        is(GP_Mode('Geo.New'),'disabled',"$fault: failed migration disables the Geo resident");
        like((GP_Auth('Geo.New'))[0],qr/migrate credentials/,"$fault: stale credentials remain unusable");
        GP_ResetController($c);
        ok(!defined((GP_Auth('Geo.New'))[1]),"$fault: session reset does not trust a leftover key");
        like(join(' ',map {$_->[2]} @logs),qr/Could not migrate webhook credentials/,"$fault: failure is visible in the operational log");
        like(GeoPresence_Set($defs{'Geo.New'},'Geo.New','webhookPassword','replacement_password_0123456789'),qr/password stored/i,
            "$fault: explicit password setup repairs the binding");
        is(GP_Read('Geo.New','gp_auth_error',''),'','repair clears the persisted error');
        ok(!defined((GP_Auth('Geo.New'))[0]),'repaired credentials pass the key-store check');
    }
};

subtest 'ROOMMATE ignores only one attributed Home echo for the current status command' => sub {
    for my $case (qw(normal foreign_pending foreign_planned absent missing_origin repeated combined combined_many late_home late_absent)) {
        my ($c,$cfg,$other_cfg)=shared_actor_fixture();
        my $s=GP_State($c,'Geo.Test',0);
        advance(40);process($s,$cfg,'Work',0);advance(90);actor_fresh();
        process($s,$cfg,'Home',1,'automotive');
        complete_arrival($s,$cfg) unless $case eq 'foreign_pending';
        my $revision=$s->{output_revision};
        my $foreign=$case =~ /^foreign/;
        my $publisher=$foreign ? 'Geo.Other':'Geo.Test';
        my $publisher_cfg=$foreign ? $other_cfg:$cfg;
        my $pub=GP_State($c,$publisher,0);
        my $pub_revision=$pub->{output_revision};
        my $absent=$case eq 'absent' || $case eq 'late_absent';
        $pub->{desired_status}=$absent ? 'absent':'home';
        reading($publisher_cfg->{roommate},'state',$absent ? 'home':'absent',$now);
        my $original=\&CommandSet;
        {
            no warnings 'redefine';
            local *CommandSet=sub {
                my ($client,$command)=@_;
                return $original->(@_) unless $command =~ /^(rr_\w+) state (\w+)$/;
                my ($name,$status)=($1,$2);
                push @commands,$command;
                $defs{$name}{CL}=$client;
                delete $defs{$name}{CL} if $case eq 'missing_origin';
                reading($name,'state',$status,$now);
                local $defs{$name}{CHANGED}=$case =~ /^combined/ ? ['home','state: home']:["state: $status"];
                push @{$defs{$name}{CHANGED}},('mood: happy') x 16,'home' if $case eq 'combined_many';
                GeoPresence_Notify($c,$defs{$name});
                roommate_event($c,'rr_Test','home') if $foreign || $case eq 'absent' || $case eq 'repeated';
                if ($case =~ /^late_/) {
                    reading($name,'state','home',$now);
                    push @{$defs{$name}{CHANGED}},'home';
                }
                delete $defs{$name}{CL};
                return;
            };
            GP_Publish($c,$publisher,$publisher_cfg,$pub);
        }
        if ($case eq 'normal') {
            is($s->{output_revision},$revision,'own Home echo preserves the output permission');
            is(scalar @{$s->{intents}},2,'own echo retains both valid opening plans');
        } else {
            cmp_ok($s->{output_revision},'>',$revision,"$case: manual or ambiguous Home revokes permission");
            ok(!$s->{trip} && !$s->{arrival},"$case: trip and waiting arrival are cancelled");
            is(scalar @{$s->{intents}},0,"$case: no opening plan survives");
            is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none',
                "$case: saved permission is revoked");
        }
        is($pub->{output_revision},$pub_revision,"$case: other person's own echo remains harmless") if $foreign;
        ok(!$c->{helper}{gp}{status_request},"$case: request marker ends with the command");
        ok(!defined $defs{$publisher_cfg->{roommate}}{CL},"$case: no command client is retained");
        complete_arrival($s,$cfg);
        GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        is(scalar(grep {/^(?:door|garage) /} @commands),$case eq 'normal' ? 2:0,
            "$case: only the normal own echo retains valid physical outputs");
    }
};

subtest 'late Home in another ROOMMATE batch revokes waiting and planned arrivals' => sub {
    for my $planned (0,1) {
      for my $batches (1,2) {
        my ($c,$cfg,$other_cfg)=shared_actor_fixture();my $s=GP_State($c,'Geo.Test',0);
        advance(40);process($s,$cfg,'Work',0);advance(90);actor_fresh();
        process($s,$cfg,'Home',1,'automotive');complete_arrival($s,$cfg) if $planned;
        my $revision=$s->{output_revision};
        my $other=GP_State($c,'Geo.Other',0);my $other_revision=$other->{output_revision};
        $other->{desired_status}='home';reading('rr_Other','state','absent',$now);
        my $original=\&CommandSet;
        {
            no warnings 'redefine';
            local *CommandSet=sub {
                return $original->(@_) unless $_[1] eq 'rr_Other state home';
                push @commands,$_[1];local $defs{rr_Other}{CL}=$_[0];
                roommate_event($c,'rr_Other','home');
                for my $batch (1..$batches) {
                    local $defs{rr_Test}{CHANGED}=[$batch==1 ? 'mood: happy':'mood: calm'];
                    GeoPresence_Notify($c,$defs{rr_Test});
                    if ($batch==1) {
                        reading('rr_Test','state','home',$now);
                        push @{$defs{rr_Test}{CHANGED}},'home';
                    }
                }
                return;
            };
            GP_Publish($c,'Geo.Other',$other_cfg,$other);
        }
        cmp_ok($s->{output_revision},'>',$revision,"planned=$planned, batches=$batches: late foreign Home revokes permission");
        ok(!$s->{trip} && !$s->{arrival},'the affected trip and arrival are cancelled');
        is(scalar @{$s->{intents}},0,'no planned opening remains');
        is($other->{output_revision},$other_revision,'the publishing resident keeps its own valid context');
        is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none','persisted permission is cleared');
        complete_arrival($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        is(scalar(grep {/^(?:door|garage) /} @commands),0,'no delayed physical opening follows');
      }
    }
};

subtest 'mapped Home has the same meaning in immediate and delayed ROOMMATE events' => sub {
    for my $case (qw(own_echo own_absent_echo own_absent own_cycle foreign)) {
        my ($c,$cfg,$other_cfg)=shared_actor_fixture();my $s=GP_State($c,'Geo.Test',0);
        advance(40);process($s,$cfg,'Work',0);advance(90);actor_fresh();
        my $absence_echo=$case eq 'own_absent_echo';
        unless ($absence_echo) {process($s,$cfg,'Home',1,'automotive');complete_arrival($s,$cfg);}
        $attr{rr_Test}{eventMap}=$absence_echo ? 'home:Zuhause absent:home':'home:Zuhause';
        my $revision=$s->{output_revision};
        my $foreign=$case eq 'foreign';my $r=$foreign ? 'Geo.Other':'Geo.Test';
        my $pub_cfg=$foreign ? $other_cfg:$cfg;my $pub=GP_State($c,$r,0);
        my $absent=$case eq 'own_absent' || $absence_echo;
        $pub->{desired_status}=$absent ? 'absent':'home';
        reading($pub_cfg->{roommate},'state',$absent ? 'home':'absent',$now);
        my $original=\&CommandSet;
        {
            no warnings qw(redefine once);
            local *deviceEvents=sub {return $_[1] && defined $_[0]{CHANGEDWITHSTATE}
                ? $_[0]{CHANGEDWITHSTATE}:$_[0]{CHANGED};};
            local *ReplaceEventMap=sub {
                return @{$_[1]} unless $_[2];
                return 'Zuhause' if $_[0] eq 'rr_Test' && $_[1] eq 'home';
                return 'home' if $absence_echo && $_[0] eq 'rr_Test' && $_[1] eq 'absent';
                return $_[1];
            };
            local *CommandSet=sub {
                my ($client,$command)=@_;
                return $original->(@_) unless $command =~ /^(rr_\w+) state (\w+)$/;
                my ($name,$status)=($1,$2);push @commands,$command;
                local $defs{$name}{CL}=$client;
                roommate_event($c,$name,$status) if $foreign;
                reading('rr_Test','state',$foreign ? 'absent':$status,$now);
                local $defs{rr_Test}{CHANGED}=[$foreign ? 'mood: happy':ReplaceEventMap('rr_Test',$status,1)];
                $defs{rr_Test}{CHANGEDWITHSTATE}=["state: $status"] unless $foreign;
                GeoPresence_Notify($c,$defs{rr_Test});
                unless ($case eq 'own_echo' || $absence_echo) {
                    reading('rr_Test','state','home',$now);
                    $defs{rr_Test}{CHANGEDWITHSTATE}=[];
                    push @{$defs{rr_Test}{CHANGED}},'Zuhause';
                }
                delete $defs{rr_Test}{CHANGEDWITHSTATE};
                return;
            };
            GP_Publish($c,$r,$pub_cfg,$pub);
        }
        if ($case eq 'own_echo') {
            is($s->{output_revision},$revision,'normal mapped own echo keeps the permission');
            is(scalar @{$s->{intents}},2,'normal mapped echo preserves both valid plans');
        } elsif ($absence_echo) {
            is($s->{output_revision},$revision,'absence mapped to the text home does not revoke the trip');
            ok($s->{trip}{armed},'the actual absence retains its qualified trip');
        } else {
            cmp_ok($s->{output_revision},'>',$revision,"$case: mapped late Home revokes permission");
            ok(!$s->{trip} && !$s->{arrival},'no trip or pending arrival survives');
            is(scalar @{$s->{intents}},0,'no output plan survives the mapped Home');
        }
    }
};

subtest 'mapped Home labels with Reading prefixes revoke after the event view was deleted' => sub {
    for my $label ('state: Zuhause','arrival: Zuhause','mood: Zuhause') {
      for my $case (qw(pending planned mood duration absent)) {
        my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
        advance(40);process($s,$cfg,'Work',0);advance(90);actor_fresh();
        unless ($case eq 'absent') {
            process($s,$cfg,'Home',1,'automotive');
            complete_arrival($s,$cfg) unless $case eq 'pending';
        }
        $attr{rr_Test}{eventMap}="{ dev=>{'^home\$'=>'$label'}, usr=>{'^$label\$'=>'home'} }";
        reading('rr_Test','state',$case eq 'absent' ? 'absent':'home',$now);
        my $revision=$s->{output_revision};
        my $event=$case eq 'mood' ? 'mood: happy'
            : $case eq 'duration' ? 'durTimerPresence: 00:01:00'
            : $case eq 'absent' ? 'absent':$label;
        {
            no warnings qw(redefine once);
            local *ReplaceEventMap=sub {
                return $_[1] eq 'home' ? $label:$_[1] if $_[2];
                my ($device,$event)=@{$_[1]};
                return ($device,'home') if $event eq $label;
                return @{$_[1]};
            };
            local $defs{rr_Test}{CHANGED}=[$event];
            delete $defs{rr_Test}{CHANGEDWITHSTATE};
            GeoPresence_Notify($c,$defs{rr_Test});
        }
        if ($case eq 'pending' || $case eq 'planned') {
            cmp_ok($s->{output_revision},'>',$revision,"$label, $case: actual Home revokes permission");
            ok(!$s->{trip} && !$s->{arrival},'trip and waiting arrival are cancelled');
            is(scalar @{$s->{intents}},0,'no planned opening survives');
        } else {
            is($s->{output_revision},$revision,"$label, $case: an unrelated event preserves permission");
            ok($s->{trip}{armed},'ordinary absence retains its trip') if $case eq 'absent';
        }
        complete_arrival($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        my $expected=$case eq 'mood' || $case eq 'duration' ? 2:0;
        is(scalar(grep {/^(?:door|garage) /} @commands),$expected,
            'only unaffected completed arrivals can issue their existing openings');
      }
    }
};

subtest 'reverse event mappings retain Home after multiple prefixed translations' => sub {
    for my $depth (2,8) {
      for my $prefix (qw(state arrival)) {
       for my $planned (0,1) {
        for my $cached (0,1) {
            my ($c,$cfg)=pending_fixture('automotive');my $s=GP_State($c,'Geo.Test',0);
            complete_arrival($s,$cfg) if $planned;
            my @labels=map {"$prefix: Place$_"} 1..$depth;
            my %forward=(home=>$labels[0],map {$labels[$_-1]=>$labels[$_]} 1..$#labels);
            my %reverse=map {$_=>'home'} @labels;
            $reverse{$labels[-1]}='state home' if $prefix eq 'arrival';
            my $dev=join(',',map {"'^$_\$'=>'$forward{$_}'"} sort keys %forward);
            my $usr=join(',',map {"'^$_\$'=>'$reverse{$_}'"} sort keys %reverse);
            $attr{rr_Test}{eventMap}="{ dev=>{$dev}, usr=>{$usr} }";
            reading('rr_Test','state','home',$now);my $revision=$s->{output_revision};
            {
                no warnings qw(redefine once);
                local *ReplaceEventMap=sub {
                    my ($name,$value,$direction)=@_;
                    return $forward{$value}//$value if $direction;
                    my ($device,$event)=@$value;
                    return ($device,split / /,$reverse{$event}) if exists $reverse{$event};
                    return @$value;
                };
                local *deviceEvents=sub {return $_[0]{CHANGEDWITHSTATE}//$_[0]{CHANGED};};
                local $defs{rr_Test}{CHANGED}=[$labels[-1],'mood: happy'];
                $defs{rr_Test}{CHANGEDWITHSTATE}=[$labels[-1],'mood: happy'] if $cached;
                delete $defs{rr_Test}{CHANGEDWITHSTATE} unless $cached;
                GeoPresence_Notify($c,$defs{rr_Test});
                delete $defs{rr_Test}{CHANGEDWITHSTATE};
            }
            cmp_ok($s->{output_revision},'>',$revision,
                "depth=$depth, $prefix, planned=$planned, cached=$cached: final Home value revokes permission");
            ok(!$s->{trip} && !$s->{arrival},'no trip or waiting arrival survives');
            is(scalar @{$s->{intents}},0,'no opening plan survives');
            complete_arrival($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
            is(scalar(grep {/^(?:door|garage) /} @commands),0,'no old physical output is issued');
        }
       }
      }
    }
};

subtest 'Home revocation survives repeated mapping and deleted state event views' => sub {
    for my $case (qw(direct direct_uncached direct_deleted own_absent own_absent_deleted
                     foreign foreign_deleted own_cycle own_cycle_deleted mood_only mood_only_deleted)) {
        (my $base=$case)=~s/_deleted$//;
        my $deleted=$case =~ /_deleted$/;
        my ($c,$cfg,$other_cfg)=shared_actor_fixture();my $s=GP_State($c,'Geo.Test',0);
        advance(40);process($s,$cfg,'Work',0);advance(90);actor_fresh();
        unless ($base eq 'own_absent') {
            process($s,$cfg,'Home',1,'automotive');
            complete_arrival($s,$cfg) if $base eq 'own_cycle' || $base eq 'mood_only';
        }
        $attr{rr_Test}{eventMap}='/home:at home/';
        my $revision=$s->{output_revision};
        my $foreign=$base eq 'foreign';my $r=$foreign ? 'Geo.Other':'Geo.Test';
        my $pub_cfg=$foreign ? $other_cfg:$cfg;my $pub=GP_State($c,$r,0);
        my $original=\&CommandSet;
        {
            no warnings qw(redefine once);
            local *ReplaceEventMap=sub {
                my ($name,$event,$direction)=@_;
                return @$event unless $direction;
                $event =~ s/\bhome\b/at home/ if $name eq 'rr_Test';
                return $event;
            };
            local *deviceEvents=sub {return $_[1] && defined $_[0]{CHANGEDWITHSTATE}
                ? $_[0]{CHANGEDWITHSTATE}:$_[0]{CHANGED};};
            if ($case =~ /^direct/) {
                reading('rr_Test','state','home',$now);
                local $defs{rr_Test}{CHANGED}=['lastState: absent','at at home','mood: happy'];
                $defs{rr_Test}{CHANGEDWITHSTATE}=$base eq 'direct' ? ['state: home']:[];
                delete $defs{rr_Test}{CHANGEDWITHSTATE} if $deleted;
                GeoPresence_Notify($c,$defs{rr_Test});
                delete $defs{rr_Test}{CHANGEDWITHSTATE};
            } else {
                $pub->{desired_status}=$base eq 'own_absent' ? 'absent':'home';
                reading($pub_cfg->{roommate},'state',$base eq 'own_absent' ? 'home':'absent',$now);
                local *CommandSet=sub {
                    my ($client,$command)=@_;
                    return $original->(@_) unless $command =~ /^(rr_\w+) state (\w+)$/;
                    my ($name,$status)=($1,$2);push @commands,$command;
                    $defs{$name}{CL}=$client;
                    reading($name,'state',$status,$now);
                    local $defs{$name}{CHANGED}=['lastState: '.($status eq 'home' ? 'absent':'home'),ReplaceEventMap($name,$status,1)];
                    $defs{$name}{CHANGEDWITHSTATE}=["state: $status"];
                    GeoPresence_Notify($c,$defs{$name});
                    delete $defs{$name}{CHANGEDWITHSTATE} if $deleted;
                    if ($foreign) {
                        local $defs{rr_Test}{CHANGED}=['mood: happy'];
                        delete $defs{rr_Test}{CHANGEDWITHSTATE};
                        GeoPresence_Notify($c,$defs{rr_Test});
                        delete $defs{rr_Test}{CHANGEDWITHSTATE} if $deleted;
                        reading('rr_Test','state','home',$now);
                        $defs{rr_Test}{CHANGEDWITHSTATE}=[];
                        push @{$defs{rr_Test}{CHANGED}},'lastState: absent','home';
                        for (1..5) {$_=ReplaceEventMap('rr_Test',$_,1) for @{$defs{rr_Test}{CHANGED}};}
                        delete $defs{rr_Test}{CHANGEDWITHSTATE};
                    } else {
                        if ($base eq 'mood_only') {push @{$defs{$name}{CHANGED}},'mood: happy';}
                        else {
                            reading($name,'state','home',$now);
                            $defs{$name}{CHANGEDWITHSTATE}=[];
                            push @{$defs{$name}{CHANGED}},'lastState: at home','absent' if $base eq 'own_cycle';
                            push @{$defs{$name}{CHANGED}},'lastState: absent','home';
                        }
                        for (1..5) {$_=ReplaceEventMap($name,$_,1) for @{$defs{$name}{CHANGED}};}
                    }
                    delete $defs{$name}{CHANGEDWITHSTATE};
                    delete $defs{$name}{CL};
                    return;
                };
                GP_Publish($c,$r,$pub_cfg,$pub);
            }
        }
        if ($base eq 'mood_only') {
            is($s->{output_revision},$revision,'later mood changes preserve the already attributed Home echo');
            is(scalar @{$s->{intents}},2,'reformatting an old Home text creates no new manual arrival');
        } else {
            cmp_ok($s->{output_revision},'>',$revision,"$case: Home revokes permission despite repeated mapping");
            ok(!$s->{trip} && !$s->{arrival},'no trip or waiting arrival survives');
            is(scalar @{$s->{intents}},0,'no old output plan survives');
        }
        complete_arrival($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        is(scalar(grep {/^(?:door|garage) /} @commands),$base eq 'mood_only' ? 2:0,
            'only the original valid own echo can retain opening commands');
        ok(!exists $defs{rr_Test}{CHANGEDWITHSTATE},'finished event views are not restored onto the device');
    }
};

subtest 'nested own ROOMMATE status commands retain both residents and restore the Reading writer' => sub {
    my ($c,$cfg,$other_cfg)=shared_actor_fixture();advance(40);
    my $s=GP_State($c,'Geo.Test',0);my $other=GP_State($c,'Geo.Other',0);
    process($s,$cfg,'Work',0);process($other,$other_cfg,'Work',0);advance(90);actor_fresh();
    process($s,$cfg,'Home',1,'automotive');complete_arrival($s,$cfg);
    process($other,$other_cfg,'Home',1,'automotive');complete_arrival($other,$other_cfg);
    reading('rr_Test','state','absent',$now);reading('rr_Other','state','absent',$now);
    my ($revision,$other_revision)=($s->{output_revision},$other->{output_revision});
    my $writer=\&setReadingsVal;
    {
        no warnings 'redefine';
        local *CommandSet=sub {
            my ($client,$command)=@_;
            my ($name)=$command =~ /^(rr_\w+) state home$/ or die "Unexpected command $command";
            push @commands,$command;$defs{$name}{CL}=$client;
            GP_Publish($c,'Geo.Other',$other_cfg,$other) if $name eq 'rr_Test';
            roommate_event($c,$name,'home');delete $defs{$name}{CL};
            return;
        };
        GP_Publish($c,'Geo.Test',$cfg,$s);
    }
    is($s->{output_revision},$revision,'outer status command keeps its output permission');
    is($other->{output_revision},$other_revision,'nested status command keeps its output permission');
    is(scalar @{$s->{intents}},2,'outer resident retains both valid opening plans');
    is(scalar @{$other->{intents}},2,'nested resident retains both valid opening plans');
    is(\&setReadingsVal,$writer,'nested status calls restore the original Reading writer');
    ok(!$c->{helper}{gp}{status_request},'no temporary status context survives');
};

subtest 'ROOMMATE failures remain visible and retry until the state is synchronized' => sub {
    for my $exception (0,1) {
        my ($c,$cfg)=fixture();advance(40);my $s=GP_State($c,'Geo.Test',0);$s->{phase}='home';$s->{desired_status}='home';
        reading('rr_Test','state','absent',$now);my $original=\&CommandSet;my $writer=\&setReadingsVal;my $fail=1;
        {
            no warnings 'redefine';
            local *CommandSet=sub {
                if ($fail && $_[1] eq 'rr_Test state home') {
                    $defs{rr_Test}{CL}=$_[0];push @commands,$_[1];
                    die "roommate unavailable\n" if $exception;return 'roommate unavailable';
                }
                return $original->(@_);
            };
            GP_Publish($c,'Geo.Test',$cfg,$s);GP_Publish($c,'Geo.Test',$cfg,$s);
            is(\&setReadingsVal,$writer,'the original Reading writer is restored after failure or exception');
            ok(!defined $defs{rr_Test}{CL},'failure does not retain the temporary command client');
            ok(!$c->{helper}{gp}{status_request},'failure does not retain an own-echo exception');
            is($s->{desired_status},'home','failed status stays pending');
            like(GP_Read('Geo.Test','gp_roommate_error',''),qr/roommate unavailable/,'Reading exposes the status failure');
            is(scalar(grep {$_->[2]=~/Could not update ROOMMATE/} @logs),1,'identical repeated failure is logged once');
            $fail=0;GP_Publish($c,'Geo.Test',$cfg,$s);
            is(GP_Read('rr_Test','state',''),'home','next successful attempt synchronized the actual ROOMMATE');
            is(GP_Read('Geo.Test','gp_roommate_error',''),'','successful update clears the error');
            ok(!exists $s->{desired_status},'successful request is consumed');
            GP_Publish($c,'Geo.Test',$cfg,$s);
        }
        is(scalar @commands,3,'two failures and one successful idempotent update; no further retry');
        is(scalar(grep {$_->[2]=~/status update accepted again/} @logs),1,'recovery is logged once');
        is(scalar(grep {/^(?:door|garage) /} @commands),0,'status retry cannot issue a physical opening');
    }
};

subtest 'command and log callbacks cannot restore obsolete or superseded requests' => sub {
    for my $source (qw(command failure_log recovery_log)) {
      for my $change (qw(status mode)) {
        my ($c,$cfg)=fixture();advance(40);my $s=GP_State($c,'Geo.Test',0);$s->{desired_status}='home';
        reading('rr_Test','state','absent',$now);
        my $events=@reading_events;
        my $update=sub {$change eq 'status' ? ($s->{desired_status}='absent') : mode('Geo.Test','debug');};
        $s->{roommate_error}='prior failure' if $source eq 'recovery_log';
        $on_log=sub {
            $update->() if ($source eq 'failure_log' && $_[2]=~/Could not update ROOMMATE/)
                || ($source eq 'recovery_log' && $_[2]=~/status update accepted again/);
        };
        no warnings 'redefine';
        local *CommandSet=sub {
            $update->() if $source eq 'command';
            return $source eq 'recovery_log' ? undef:'callback failure';
        };
        GP_Publish($c,'Geo.Test',$cfg,$s);
        if ($change eq 'status') {is($s->{desired_status},'absent',"$source: newer status wins over the older request");}
        else {
            ok(!exists $s->{desired_status},"$source: mode change prevents restoring the obsolete request");
            is(scalar @reading_events,$events,"$source: invalidated context publishes no resident events");
        }
      }
    }
};

subtest 'HTTP response, disabled input, request rate and method validation' => sub {
    my ($c,$cfg)=fixture();advance(40);
    my $headers={'content-type'=>'application/x-www-form-urlencoded'};
    is((GP_HTTP($c,'GET','/fhem/geopresence',$headers,''))[0],405,'GET has no effect');
    is((GP_HTTP($c,'POST','/fhem/geopresence',{},''))[0],415,'unexpected format rejected');
    like(GP_HTTPResponse(GP_HTTP($c,'POST','/fhem/geopresence',$headers,'entry=1')),
        qr/HTTP\/1.1 401.*WWW-Authenticate/s,'response contains status and authentication challenge');
    for (1..120) {http($c,form($cfg,'Home',1,$now));}
    is((http($c,form($cfg,'Home',1,$now)))[0],429,'bounded request rate');
    advance(61);mode('Geo.Test','disabled');GeoPresence_Timer($c);
    is((http($c,form($cfg,'Home',1,$now)))[0],503,'disabled resident cannot queue');
};

subtest 'HTTP route diagnostics preserve exact paths and early rejection details' => sub {
    my ($c)=fixture();advance(40);
    my $dir=tempdir(CLEANUP=>1);$attr{GP}{logFile}="$dir/http.log";$attr{GP}{debugLog}=1;
    my $form={'content-type'=>'application/x-www-form-urlencoded'};
    for my $case (
        ['GET','/fhem/other',$form,'',404,'unknown'],
        ['POST','/fhem/geopresence/debug',$form,'',404,'unknown'],
        ['POST','/fhem/geopresence?cmd=set',$form,'',404,'unknown'],
        ['GET','/fhem/geopresence',$form,'',405,'webhook'],
        ['POST','/fhem/geopresence',{},'',415,'webhook'],
        ['POST','/fhem/geopresence',$form,'x'x16385,413,'webhook'],
        ['POST','/fhem/geopresence',$form,'',401,'webhook']) {
        my ($method,$path,$headers,$body,$expected,$route)=@$case;
        my ($status,$text)=GP_HTTP($c,$method,$path,$headers,$body);
        is($status,$expected,"$method $path: same rejection status");
        my @lines=diagnostic_lines($c);my ($json)=$lines[-1]=~/GeoPresence http (\{.*\})/;
        my $row=JSON::PP::decode_json($json);
        is_deeply([@{$row}{qw(route status reason)}],[$route,$status,$text],
            'diagnosis retains the route, response status and reason');
        ok(!exists $row->{resident},'early rejection has no unverified person');
    }
    is(scalar @{$c->{helper}{gp}{queue}},0,'rejected requests queued no observations');
};

subtest 'HTTP authentication rejects ambiguous catalog users without changing the catalog' => sub {
    my ($c)=shared_actor_fixture();advance(40);
    $attr{'Geo.Other'}{webhookUser}='user';config_event('ATTR Geo.Other webhookUser user');
    my $matches=GP_Catalog($c)->{users}{user};my @before=@$matches;
    is(scalar @before,2,'configuration has two residents sharing one username');
    for (1..2) {
        is((http($c,'isTest=invalid'))[0],401,'ambiguous identity is rejected before content or quota processing');
    }
    is_deeply($matches,\@before,'authentication leaves the shared user index unchanged');
    ok(!exists $c->{helper}{gp}{http_rate},'ambiguous identity allocated no person quota');
};

subtest 'failed authentication cannot consume a resident webhook quota' => sub {
    my ($c,$cfg)=fixture();advance(40);
    my $body=form($cfg,'Home',1,$now);
    for my $auth ('','Bearer invalid','Basic '.encode_base64('user:wrong',''),
            'Basic '.encode_base64('unknown:password123456789012345678','')) {
        my @status=map {(http($c,$body,undef,$auth))[0]} 1..121;
        is_deeply(\@status,[(401)x121],'failed authentication stays HTTP 401 beyond the processing quota');
    }
    is(scalar @{$c->{helper}{gp}{queue}},0,'unauthenticated requests queued nothing');
    my @status=map {(http($c,$body))[0]} 1..120;
    is_deeply(\@status,[(200)x120],'all 120 authenticated requests remain available after the failed logins');
    is((http($c,$body))[0],429,'the next authenticated request reaches the resident limit');
    is((http($c,$body,undef,''))[0],401,'an exhausted quota does not replace the authentication challenge');
    is(scalar @{$c->{helper}{gp}{queue}},120,'only authenticated requests below the limit reached the queue');
    is_deeply([\@commands,\@messages],[[],[]],'authentication and quota checks produced no outputs');
};

subtest 'residents have independent quotas shared by all modes' => sub {
    my ($c,$cfg)=shared_actor_fixture();advance(40);
    # Authenticated invalid payloads exercise the processing limit without
    # filling the independent, controller-wide observation queue.
    my @status=map {(http($c,'isTest=invalid'))[0]} 1..120;
    is_deeply(\@status,[(400)x120],'authenticated invalid payloads also consume processing capacity');
    is((http($c,'isTest=invalid'))[0],429,'first resident exhausted its own quota');
    mode('Geo.Test','debug');
    is((http($c,'isTest=true'))[0],429,'changing mode cannot renew the same resident quota');
    advance(30);
    my $other='Basic '.encode_base64('other-user:password123456789012345678','');
    is((http($c,form($cfg,'Home',1,$now,device=>'other-device'),undef,$other))[0],200,
        'another resident can still submit a valid observation');
    @status=map {(http($c,'isTest=invalid',undef,$other))[0]} 1..119;
    is_deeply(\@status,[(400)x119],'second resident retained its remaining quota');
    is((http($c,'isTest=invalid',undef,$other))[0],429,'second resident has the same independent limit');
    advance(30);
    is((http($c,'isTest=invalid'))[0],400,'first resident renews after its own 60 seconds');
    is((http($c,'isTest=invalid',undef,$other))[0],429,'renewing one window cannot renew another resident');
    advance(30);
    is((http($c,'isTest=invalid',undef,$other))[0],400,'second resident renews at its own deadline');
    mode('GP','debug');
    is(GeoPresence_Undef($defs{'Geo.Other'}),undef,'resident can be removed normally');
    ok(!exists $c->{helper}{gp}{http_rate}{'Geo.Other'},'removing a resident releases its quota entry');
};

subtest 'quota diagnostics retain the authenticated resident' => sub {
    my $dir=tempdir(CLEANUP=>1);
    for my $case ([debug=>'auto',1],[learning=>'auto',1],[active=>'1',1],[active=>'auto',0],[debug=>'0',0]) {
        my ($resident_mode,$setting,$enabled)=@$case;
        my ($c)=fixture();advance(40);
        if ($resident_mode eq 'learning') {
            like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','mode','learning'),qr/^Learning for/,'learning started');
        } else { mode('Geo.Test',$resident_mode); }
        $attr{GP}{logFile}="$dir/$resident_mode-$setting.log";
        $attr{GP}{debugLog}=$setting;
        is(GP_Mode('GP'),'active','controller remains active for the mixed-mode diagnosis');
        my @status=map {(http($c,'isTest=invalid'))[0]} 1..120;
        is_deeply(\@status,[(400)x120],"$resident_mode / $setting: authenticated requests fill the quota");
        is((http($c,'isTest=invalid'))[0],429,"$resident_mode / $setting: excess request is limited");
        my @rows=map {JSON::PP::decode_json(/GeoPresence http (\{.*\})/ ? $1:'{}')} diagnostic_lines($c);
        my @limited=grep {($_->{status}//0)==429} @rows;
        is(scalar @limited,$enabled,"$resident_mode / $setting: quota diagnosis follows the configured switch");
        if ($enabled) {
            is($limited[0]{resident},'Geo.Test','HTTP 429 belongs to the authenticated resident');
            is($limited[0]{reason},'Rate limit','quota reason remains available');
        }
        is((http($c,'isTest=invalid',undef,'Basic '.encode_base64('user:wrong','')))[0],401,'wrong password remains unauthenticated');
        @rows=map {JSON::PP::decode_json(/GeoPresence http (\{.*\})/ ? $1:'{}')} diagnostic_lines($c);
        ok(!scalar(grep {($_->{status}//0)==401 && exists $_->{resident}} @rows),
            'failed authentication cannot attach an unverified resident to the diagnosis');
        unlike(join('',diagnostic_lines($c)),qr/password123456789012345678|Basic |user:wrong/,'credentials stay out of the diagnosis');
    }
};

subtest 'webhook quota duration is independent of wall clock corrections' => sub {
    for my $shift (-3600,0,3600) {
        my ($c)=fixture();advance(40);
        my @status=map {(http($c,'isTest=invalid'))[0]} 1..120;
        is_deeply(\@status,[(400)x120],"wall shift $shift: full quota initially available");
        $now+=$shift;$mono+=59;
        is((http($c,'isTest=invalid'))[0],429,"wall shift $shift: no renewal after 59 elapsed seconds");
        $mono+=1;
        is((http($c,'isTest=invalid'))[0],400,"wall shift $shift: renewal exactly at 60 monotonic seconds");
        @status=map {(http($c,'isTest=invalid'))[0]} 1..119;
        is_deeply(\@status,[(400)x119],"wall shift $shift: renewed window has its full capacity");
        is((http($c,'isTest=invalid'))[0],429,"wall shift $shift: renewed window is limited again");
    }
};

subtest 'dedicated HTTP framing bounds and ambiguity rejection' => sub {
    my $prefix="POST /fhem/geopresence HTTP/1.1\r\nHost: localhost\r\n";
    my $wire=$prefix."cOnTeNt-LeNgTh: 7\r\naUtHoRiZaTiOn: Basic test\r\n\r\nentry=1";
    for my $cut (1,length($prefix),length($wire)-1) {
        is_deeply([GP_HTTPFrame(substr($wire,0,$cut))],[],"fragment of $cut bytes waits without processing");
    }
    my ($frame)=GP_HTTPFrame($wire);
    is($frame->{body},'entry=1','complete body kept separate from path');
    is($frame->{headers}{authorization},'Basic test','header names are case insensitive');
    is((GP_HTTPFrame($prefix.'X-Large: '.('x'x8192)))[1],431,'header storage bounded before body arrives');
    is((GP_HTTPFrame($prefix."Content-Length: 16385\r\n\r\n"))[1],413,'oversize rejected before body arrives');
    my ($limit)=GP_HTTPFrame($prefix."Content-Length: 16384\r\n\r\n".('x'x16384));
    is(length($limit->{body}),16384,'documented body limit accepted');
    for my $bad ("Content-Length: 0\r\ncontent-length: 0", "Content-Length: -1", "Content-Length: 1,1",
        "Content-Length: 0\r\nTransfer-Encoding: chunked", "Authorization: one\r\nauthorization: two",
        " Content-Length: 0", "Content-Length: 0\nX-Test: bad", "Content-Length: 0\r\nX-Test: \0") {
        is((GP_HTTPFrame($prefix.$bad."\r\n\r\n"))[1],400,'ambiguous or malformed headers rejected');
    }
    is((GP_HTTPFrame($prefix."Expect: 100-continue\r\nContent-Length: 0\r\n\r\n"))[1],417,'expectation rejected');
    is((GP_HTTPFrame($prefix."\r\n"))[1],411,'POST requires content length');
    is((GP_HTTPFrame("POST /fhem/geopresence HTTP/1.1\r\nContent-Length: 0\r\n\r\n"))[1],400,'HTTP/1.1 requires host');
    is((GP_HTTPFrame($wire.$wire))[1],400,'pipelined request never becomes another event');
    unlike(GP_HTTPResponse(401,'Authentication required'),qr/csrf/i,'listener does not expose a FHEM CSRF token');
};

subtest 'webhook commands cannot reach FHEM and old callbacks are removed' => sub {
    my ($c,$cfg)=fixture();advance(40);
    mode('GP','debug');GeoPresence_Timer($c);
    $reading_calls=0;@commands=();@messages=();
    my $body=form($cfg,'Home',1,$now);
    for my $path ('/fhem/geopresence','/fhem/geopresence/debug') {
        is((http($c,$body,$path.'?XHR=1&cmd=set%20door%20open'))[0],404,'query cannot enter a command dispatcher');
        for my $key ('XHR','cmd','cmd.test','jsonp','fwcsrf','inform','asyncOutput','%63md') {
            is((http($c,$body."&$key=set%20door%20open",$path))[0],$path =~ /debug$/?404:400,"$key rejected even with valid credentials");
            is((http($c,$body."&$key=set%20door%20open",$path,''))[0],$path =~ /debug$/?404:401,"$key does not bypass authentication");
        }
    }
    is(scalar @{$c->{helper}{gp}{queue}},0,'no rejected request was queued');
    is(scalar @commands,0,'no FHEM command ran');is(scalar @messages,0,'no message ran');
    is($reading_calls,0,'no reading API call ran');
    $data{FWEXT}{'/geopresence'}={GP_OWNER=>'GP',FUNC=>'GeoPresence_CGI'};
    $data{FWEXT}{'/other'}={FUNC=>'Other_CGI'};
    GP_ResetController($c);GeoPresence_Timer($c);
    ok(!$data{FWEXT}{'/geopresence'},'reload removes its old FWEXT registration');
    ok($data{FWEXT}{'/other'},'other extensions remain untouched');
    is_deeply([GP_Validate($c)],[],'configuration needs only the dedicated transport');
    ok($c->{helper}{gp}{ready},'explicit port configuration starts independent listener');
    GeoPresence_Undef($c);ok(!$c->{helper}{gp_http},'undef releases listener');
};

subtest 'resident mode changes preserve other residents and placeholders are rejected' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);advance(40);process($s,$cfg,'Work',0);
    device('Geo.Other','GeoPresence');$defs{'Geo.Other'}{SUBTYPE}='resident';$defs{'Geo.Other'}{CONTROLLER}='GP';
    $defs{'Geo.Other'}{READINGS}{mode}{VAL}='debug';
    mode('Geo.Other','disabled');
    is($c->{helper}{gp}{prod}{'Geo.Test'},$s,'other resident retains same state');
    ok($s->{trip}{armed},'other resident retains qualified trip');
    mode('GP','debug');
    like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','webhookPassword','__DO_NOT_USE_THIS_PASSWORD__'),qr/placeholder/,'example placeholder cannot become a credential');
};

subtest 'one or several room sensors keep the same house presence' => sub {
    my ($c,$cfg,$s)=house_fixture();advance(40);actor_fresh();
    feed_house_phone($c,$cfg,$s,house_samples(p1=>'present'));
    for my $detected ([qw(p1 p3)],[qw(p3)],[qw(p3 p5)],[qw(p5)],[qw(p2)],[qw(p1 p2 p3 p4 p5)]) {
        advance(30);
        my $event=feed_house_phone($c,$cfg,$s,house_samples(map {$_=>'present'} @$detected));
        ok(!$event,'no new arrival when detected by '.join(',',@$detected));
        is($s->{phone}{state},'present','one positive wins over negatives from other rooms');
        is(GP_Read('rr_Test','state',''),'home','resident stays home');
    }
    is(scalar @commands,0,'moving between sensors causes no ROOMMATE or actuator command');
    is(scalar @messages,0,'moving between sensors sends no messages');
};

subtest 'brief gap between room sensors retains presence and cancels pending absence' => sub {
    my ($c,$cfg,$s)=house_fixture();advance(40);
    feed_house_phone($c,$cfg,$s,house_samples(p1=>'present'));
    advance(5);feed_house_phone($c,$cfg,$s,house_samples());
    advance(120);feed_house_phone($c,$cfg,$s,house_samples());
    is($s->{phone}{state},'present','handover retains present before 180 seconds');
    is(GP_Read('Geo.Test','gp_phone_health',''),'handover','held presence is distinguishable from a fresh detection');
    advance(1);my $event=feed_house_phone($c,$cfg,$s,house_samples(p4=>'present'));
    ok(!$event,'detection in the next room is no new arrival');
    ok(!defined($s->{phone}{negative_since}),'positive detection cancels negative interval');
    advance(5);feed_house_phone($c,$cfg,$s,house_samples());
    advance(179);feed_house_phone($c,$cfg,$s,house_samples());
    is(GP_Read('rr_Test','state',''),'home','a new negative interval cannot inherit the earlier gap');
    is(scalar @commands,0,'room handover sends no status or actuator command');
};

subtest 'brief sensor fault and room handover do not turn false Geo departure into arrival' => sub {
    my ($c,$cfg,$s)=house_fixture();advance(40);actor_fresh();
    feed_house_phone($c,$cfg,$s,house_samples(p1=>'present'));
    advance(1);process($s,$cfg,'Drive',0);
    my $samples=house_samples();$samples->{p1}{healthy}=0;
    feed_house_phone($c,$cfg,$s,$samples);
    advance(90);$samples=house_samples(p3=>'present');
    my $event=feed_house_phone($c,$cfg,$s,$samples);
    ok($event && !$event->{arrival},'next room observation repairs presence without being a new arrival');
    ok(!$s->{trip},'continuous house presence revokes the false Geo trip');
    is($s->{phase},'home','house presence restored');
    is(scalar(grep {/^(?:door|garage) /} @commands),0,'no opening even though false departure was over 60 seconds ago');
};

subtest 'false outer exit and Home return during handover never authorize opening' => sub {
    for my $signal_mode (qw(state measurement)) {
        for my $gap (qw(negative fault)) {
            my ($c,$cfg,$s)=house_fixture();$cfg->{phoneSignalMode}=$signal_mode;
            advance(40);actor_fresh();feed_house_phone($c,$cfg,$s,house_samples(p1=>'present'));
            advance(1);my $samples=house_samples();$samples->{p1}{healthy}=0 if $gap eq 'fault';
            feed_house_phone($c,$cfg,$s,$samples);
            is($s->{phone}{state},'present',"$signal_mode/$gap retains phone presence");
            is($s->{phone}{health},'handover',"$signal_mode/$gap enters handover");
            advance(1);process($s,$cfg,'Outer',0);GP_Publish($c,'Geo.Test',$cfg,$s);
            ok(!$s->{trip},"$signal_mode/$gap rejects false remote evidence without retaining a trip");
            is(GP_Read('rr_Test','state',''),'home',"$signal_mode/$gap preserves ROOMMATE home");
            advance(61);feed_house_phone($c,$cfg,$s,$samples);
            arrive($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
            GP_Publish($c,'Geo.Test',$cfg,$s);
            is(scalar(grep {/^(?:door|garage) /} @commands),0,"$signal_mode/$gap cannot open either actor during gap");
            advance(1);feed_house_phone($c,$cfg,$s,house_samples(p3=>'present'));
            is(scalar(grep {/^(?:door|garage) /} @commands),0,"$signal_mode/$gap room recovery does not open");
            advance(1);process($s,$cfg,'Home',0);advance(1);
            feed_house_phone($c,$cfg,$s,house_samples());advance(180);
            feed_house_phone($c,$cfg,$s,house_samples());
            ok($s->{trip}{armed} && $s->{trip}{scope} eq 'local',"$signal_mode/$gap a later real walk qualifies locally");
            advance(1);arrive($s,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
            is(scalar(grep {$_ eq 'door lock unlocked'} @commands),1,"$signal_mode/$gap real walk still opens door");
            is(scalar(grep {$_ eq 'garage on'} @commands),0,"$signal_mode/$gap rejected remote scope never leaks to walk");
        }
    }
};

subtest 'every configured house sensor must report negative' => sub {
    my ($c,$cfg,$s)=house_fixture();
    $cfg=GP_Config($c,'Geo.Test');advance(40);process($s,$cfg,'Home',0);
    my $samples=house_samples();$samples->{p5}{healthy}=0;
    phone_tick($s,$cfg,$samples);
    advance(200);$samples=house_samples();$samples->{p5}{healthy}=0;
    phone_tick($s,$cfg,$samples);
    ok(!$s->{trip}{armed},'four negative rooms cannot replace the missing fifth sensor');
    is($s->{phone}{state},'unknown','incomplete house coverage does not prove absence');
    advance(1);phone_tick($s,$cfg,house_samples());
    advance(179);phone_tick($s,$cfg,house_samples());
    ok(!$s->{trip}{armed},'healthy interval starts after the missing sensor returns');
    advance(1);phone_tick($s,$cfg,house_samples());
    ok($s->{trip}{armed},'all five sensors qualify absence after 180 seconds');
};

subtest 'a failure of any room sensor interrupts the negative qualification' => sub {
    my ($c,$cfg,$s)=house_fixture();advance(40);process($s,$cfg,'Home',0);
    phone_tick($s,$cfg,house_samples());
    advance(120);my $samples=house_samples();$samples->{p4}{time}=$now-151;
    phone_tick($s,$cfg,$samples);
    ok(!defined($s->{phone}{negative_since}),'stale result from any room resets negative interval');
    advance(5);phone_tick($s,$cfg,house_samples());
    advance(179);phone_tick($s,$cfg,house_samples());
    ok(!$s->{trip}{armed},'a renewed measurement alone cannot resume the old interval');
    advance(1);phone_tick($s,$cfg,house_samples());
    ok($s->{trip}{armed},'new complete negative interval qualifies');
};

subtest 'return via any room sensor still supplies the Geo arrival fallback' => sub {
    my ($c,$cfg,$s)=house_fixture();advance(40);
    feed_house_phone($c,$cfg,$s,house_samples(p1=>'present'));
    advance(5);process($s,$cfg,'Work',0);
    advance(1);feed_house_phone($c,$cfg,$s,house_samples());
    advance(180);feed_house_phone($c,$cfg,$s,house_samples());
    is(GP_Read('rr_Test','state',''),'absent','complete negative house coverage confirms absence');
    advance(1);actor_fresh();my $event=feed_house_phone($c,$cfg,$s,house_samples(p5=>'present'));
    ok($event->{arrival},'return is accepted from a different room sensor');
    is(GP_Read('rr_Test','state',''),'home','phone fallback restores home despite missing Home webhook');
    is(scalar(grep {$_ eq 'door lock unlocked'} @commands),1,'qualified return opens door once');
    is(scalar(grep {$_ eq 'garage on'} @commands),1,'remote trip also permits garage');
    advance(30);feed_house_phone($c,$cfg,$s,house_samples(p2=>'present',p5=>'present'));
    is(scalar(grep {$_ eq 'door lock unlocked'} @commands),1,'additional room detection does not repeat opening');
};

subtest 'rejected remote departure cannot contaminate the next local walk' => sub {
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);arrive($s,$cfg);
    advance(10);my $remote_time=$now;advance(1);
    my $positive=negative_samples();$positive->{p1}{value}='present';
    phone_tick($s,$cfg,$positive);
    GP_Process($s,$cfg,ev('Outer',0,$remote_time),$now,$mono);
    ok(!$s->{trip},'newer local detection leaves no rejected remote trip');
    advance(10);process($s,$cfg,'Home',0);advance(1);
    phone_tick($s,$cfg,negative_samples());advance(180);phone_tick($s,$cfg,negative_samples());
    ok($s->{trip}{armed},'real walk receives its own qualification');
    is($s->{trip}{scope},'local','new walk does not inherit rejected remote scope');
    advance(1);arrive($s,$cfg);
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'return without motion opens only the door');
};

subtest 'car departures from the September logs retain Home evidence despite held phone presence' => sub {
    for my $case (['19 September',360,19800],['20 September',444,4800]) {
        my ($label,$outbound,$away)=@$case;
        my ($c,$cfg,$s)=house_fixture();$cfg->{phoneSignalMode}='state';
        advance(40);my $held=house_samples(p1=>'present');phone_tick($s,$cfg,$held);
        advance(10);process($s,$cfg,'Home',0);my $home_exit=$now;
        advance($outbound);phone_tick($s,$cfg,$held);process($s,$cfg,'Outer',0,'automotive');
        is(($s->{trip}//{})->{home_exit},$home_exit,"$label: earlier Home exit survives rejected outer departure");
        ok(!($s->{trip}//{})->{armed},"$label: held presence does not authorize a return");
        is(($s->{trip}//{})->{scope},'local',"$label: rejected outer evidence supplies no remote scope");
        advance(5);my $negative=house_samples();phone_tick($s,$cfg,$negative);
        advance(179);phone_tick($s,$cfg,$negative);
        ok(!($s->{trip}//{})->{armed},"$label: full phone absence interval is required");
        advance(1);phone_tick($s,$cfg,$negative);
        ok(($s->{trip}//{})->{armed},"$label: qualified absence authorizes the retained Home departure");
        is($s->{desired_status},'absent',"$label: confirmed departure marks resident absent");
        advance($away);process($s,$cfg,'Outer',1,'automotive');
        advance(260);process($s,$cfg,'Home',1,'automotive');
        is(($s->{arrival}//{})->{wait},10,"$label: car return starts ten-second confirmation");
        is($s->{phase},'returning',"$label: Home entry remains provisional");
        advance(9);GP_ConfirmArrival($s,$cfg,$now,$mono);
        is(scalar @{$s->{intents}},0,"$label: no early opening");
        advance(1);GP_ConfirmArrival($s,$cfg,$now,$mono);
        is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open','garage_open'],"$label: both actors requested after ten seconds");
    }
};

subtest 'rejected outer events preserve a running Home absence qualification without refreshing it' => sub {
    for my $signal_mode ('state','measurement') {
        for my $motion ('unknown','walking','automotive') {
            my ($c,$cfg,$s)=house_fixture();$cfg->{phoneSignalMode}=$signal_mode;
            advance(40);phone_tick($s,$cfg,house_samples(p1=>'present'));
            advance(10);process($s,$cfg,'Home',0);my $home_exit=$now;
            advance(1);my $negative=house_samples();phone_tick($s,$cfg,$negative);
            my $since=$s->{phone}{negative_since};my $generation=$s->{phone}{negative_generation};
            for (1..2) {
                advance(60);$negative=house_samples() if $signal_mode eq 'measurement';
                phone_tick($s,$cfg,$negative);process($s,$cfg,'Outer',0);
                is($s->{phone}{health},'handover','short negative interval still holds presence');
                is($s->{phone}{negative_since},$since,'rejected observation does not restart the absence interval');
                is($s->{phone}{negative_generation},$generation,'rejected observation does not revoke pending negatives');
                is($s->{position_time},$home_exit,'rejected outer timestamp does not supersede actual phone observations');
                ok(!($s->{trip}//{})->{armed},'Home suspicion alone remains unarmed');
            }
            advance(60);phone_tick($s,$cfg,$negative);
            ok(($s->{trip}//{})->{armed},'unchanged negatives qualify at the original deadline');
            is(($s->{trip}//{})->{scope},'local','remote rejection never leaks into qualified trip');
            advance(10);arrive($s,$cfg,$motion);
            is_deeply([map {$_->{kind}} @{$s->{intents}}],
                $motion eq 'automotive' ? ['door_open','garage_open']:['door_open'],
                "$signal_mode/$motion return uses its own movement, not the rejected remote scope");
        }
    }
};

subtest 'retained Home departures preserve route consumption until a genuinely new trip' => sub {
    for my $case ([notify=>'enter','location'],[notify=>'exit','group'],[switch_on=>'enter','group'],[switch_on=>'exit','location']) {
        my ($type,$trigger,$selector)=@$case; my $label="$type/$trigger/$selector";
        my ($c)=fixture(); mode('GP','debug'); attribute('Geo.Test','phoneSignalMode','state');
        for my $spec (['Checkpoint',0.0009,'RouteOrigin'],['Sternensteg',0.00135,'RouteTarget']) {
            my ($zone,$lat,$group)=@$spec;
            my $g=JSON::PP::decode_json(GP_Read('Z.'.$zone,'gp_geometry',''));
            @{$g}{qw(lat radius)}=($lat,20);
            reading('Z.'.$zone,'gp_geometry',JSON::PP::encode_json($g),$now-1000);
            attribute('Z.'.$zone,'groups',$group);
        }
        my $action='A.Msg';
        if ($type eq 'switch_on') {
            device('routeLamp','dummy'); gp_define('A.RouteLight','action GP switch_on');
            attribute('A.RouteLight','target','routeLamp'); attribute('A.RouteLight','command','on'); $action='A.RouteLight';
        }
        gp_define('R.NearRoute','rule GP'); attribute('R.NearRoute','residents','Geo.Test');
        attribute('R.NearRoute','trigger',$trigger); attribute('R.NearRoute','action',$action); attribute('R.NearRoute','cooldown',0);
        attribute('R.NearRoute',$selector eq 'group' ? 'locationGroup':'locations',
            $selector eq 'group' ? 'RouteTarget':'Z.Sternensteg');
        attribute('R.NearRoute','afterExit',$selector eq 'group' ? 'group:RouteOrigin':'location:Z.Checkpoint');
        mode('GP','active'); GeoPresence_Timer($c);
        my $cfg=GP_Config($c,'Geo.Test'); my $s=GP_State($c,'Geo.Test',0); advance(40);
        my $samples=negative_samples(); $samples->{p1}{value}='present'; phone_tick($s,$cfg,$samples);
        my $observe=sub {
            process($s,$cfg,@_); GP_Dispatch($c,'Geo.Test',$cfg,$s,0); GP_Publish($c,'Geo.Test',$cfg,$s);
        };
        my $issued=sub {$type eq 'notify' ? scalar(@messages):scalar(grep {$_ eq 'routeLamp on'} @commands)};
        advance(1); $observe->('Home',0); my $id=$s->{trip}{id}; my $home_exit=$s->{trip}{home_exit};
        advance(10); $observe->('Checkpoint',0);
        my $entry=$trigger eq 'enter' ? 1:0;
        advance(10); $observe->('Sternensteg',$entry);
        is($issued->(),1,"$label: first route action really dispatched while departure is unarmed");
        my %consumed=%{$s->{trip}{actions}}; my $last=$s->{action_last}{$action};
        for my $repeat (1..2) {
            advance(10); $observe->('Outer',0);
            is($s->{trip}{id},$id,"$label: rejection $repeat retained the same trip");
            is($s->{trip}{home_exit},$home_exit,'original Home exit retained');
            ok(!$s->{trip}{armed} && $s->{trip}{scope} eq 'local','rejection granted no remote or opening permission');
            is_deeply($s->{trip}{actions},\%consumed,'same trip retained its consumed actions');
            ok(!exists($s->{trip}{exits}),'old exit evidence was still discarded');
            for my $observation (['Checkpoint',1],['Checkpoint',0],['Sternensteg',$entry ? 0:1],['Sternensteg',$entry]) {
                advance(10); $observe->(@$observation);
            }
            is($issued->(),1,'new exit evidence and another visit did not repeat a consumed route action');
            is($s->{action_last}{$action},$last,'suppressed repetition did not renew the cooldown');
        }
        $defs{rr_Test}{CHANGED}=['home']; GeoPresence_Notify($c,$defs{rr_Test});
        advance(10); $observe->('Home',0);
        isnt($s->{trip}{id},$id,'a later Home departure really began a new trip');
        advance(10); $observe->('Checkpoint',0); advance(10); $observe->('Sternensteg',$entry);
        is($issued->(),2,'new trip with new exit evidence allowed the route action again');
        is(scalar(grep {/^(?:door|garage) /} @commands),0,'unconfirmed departures never opened door or garage');
    }
};

subtest 'Home or phone return revokes retained departure suspicion, including delayed observations' => sub {
    for my $return ('Home','phone','delayed phone','stale phone') {
        my ($c,$cfg,$s)=house_fixture();$cfg->{phoneSignalMode}='state';
        advance(40);phone_tick($s,$cfg,house_samples(p1=>'present'));
        advance(10);process($s,$cfg,'Home',0);
        advance(1);my $negative=house_samples();phone_tick($s,$cfg,$negative);
        advance(10);process($s,$cfg,'Outer',0);
        advance(61);
        if ($return eq 'Home') {process($s,$cfg,'Home',1,'automotive');}
        elsif ($return eq 'phone') {phone_tick($s,$cfg,house_samples(p3=>'present'));}
        else {
            my $positive=house_samples(p3=>'present');
            advance(10);process($s,$cfg,'Outer',1);my $position=$s->{position_time};
            advance($return eq 'stale phone' ? 100:1);phone_tick($s,$cfg,$positive);
            is($s->{position_time},$position,'delayed phone evidence does not rewind a newer zone observation');
        }
        ok(!$s->{trip},"$return cancels pending Home departure");
        ok(!$s->{arrival},"$return during short gap never starts an opening timer");
        is(scalar @{$s->{intents}},0,"$return during short gap creates no action");
        advance(1);$negative=house_samples();phone_tick($s,$cfg,$negative);
        advance(180);phone_tick($s,$cfg,$negative);
        ok(!($s->{trip}//{})->{armed},"$return: later phone absence cannot revive cancelled Home exit");
        advance(10);arrive($s,$cfg,'automotive');
        is(scalar @{$s->{intents}},0,"$return: car evidence alone cannot open after cancelled departure");
    }
};

subtest 'old negative phone observations cannot undo Home or DriveIn arrival' => sub {
    for my $zone ('Home','Drive') {
        my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Work',0);
        advance(1);phone_tick($s,$cfg,negative_samples());advance(180);
        my $old=negative_samples();phone_tick($s,$cfg,$old);
        is($s->{phase},'away','departure confirmed before return');
        advance(1);process($s,$cfg,$zone,1);complete_arrival($s,$cfg) if $zone eq 'Home';
        my $phase=$zone eq 'Home' ? 'home':'returning';
        is($s->{phase},$phase,"fresh $zone entry accepted");
        advance(5);phone_tick($s,$cfg,$old);GP_TickState($s,$cfg,$now,$mono);
        is($s->{phase},$phase,"same old negatives cannot overwrite $zone");
        is($s->{desired_status},$zone eq 'Home' ? 'home':'absent','ROOMMATE target remains consistent');
        ok(!$s->{phone}{qualified},'previous negative qualification is no longer reusable');
    }
};

sub phone_timeline_fixture {
    my ($signal,%options)=@_;
    my ($c)=fixture();mode('GP','debug');
    attribute('Geo.Test','phoneSignalMode',$signal);
    attribute('Geo.Test','phoneProxies','p1,p2');
    attribute('GP',$_,$options{$_}) for sort keys %options;
    my $geometry=JSON::PP::decode_json(GP_Read('Z.Checkpoint','gp_geometry',''));
    @{$geometry}{qw(lat radius)}=(0.00135,20);
    reading('Z.Checkpoint','gp_geometry',JSON::PP::encode_json($geometry),$now-1000);
    $defs{$_}{INTERVAL_NORMAL}=120 for qw(p1 p2);
    mode('GP','active');GeoPresence_Timer($c);
    actor_fresh();
    my $base=$now;
    my $at=sub {advance($base+$_[0]-$now);};
    my $sample=sub {
        my ($name,$value,$time)=@_;
        reading($name,'state',$value,$base+$time);reading($name,'presence',$value,$base+$time);
    };
    return ($c,GP_Config($c,'Geo.Test'),GP_State($c,'Geo.Test',0),$at,$sample,$base);
}

subtest 'only contradicted queued absence completions are revoked' => sub {
    for my $case (qw(contradiction mixed_positive genuine_return)) {
        my ($c,$cfg,$s,$at,$sample,$base)=phone_timeline_fixture('state',phone_absence_window=>20,reorder_window=>10);
        $at->(50);$sample->($_,'absent',50) for qw(p1 p2);
        GeoPresence_Timer($c);actor_fresh();
        $at->(100);my $exit=form($cfg,'Home',0,$now);http($c,$exit);
        $at->(110);GeoPresence_Timer($c);my $id=$s->{trip}{id};
        $at->(115);GeoPresence_Timer($c);
        $at->(134);http($c,$exit);
        $at->(135);GeoPresence_Timer($c);
        ok(grep({$_->{kind} eq 'phone_absent'} @{$s->{queued_phones}}),'completion is held by the pending Geo batch');
        if ($case eq 'contradiction') {
            $at->(140);$sample->('p1','present',90);GeoPresence_Timer($c);
            $at->(144);GeoPresence_Timer($c);
            is(($s->{trip}//{})->{id},$id,'older presence preserved the later Home departure suspicion');
            ok(!($s->{trip}//{})->{armed},'contradicted completion could not arm it');
            $at->(190);http($c,form($cfg,'Home',1,$now,motion=>'walking'));
            $at->(200);GeoPresence_Timer($c);$at->(261);GeoPresence_Timer($c);
        } else {
            $at->(190);
            $sample->('p1','present',$case eq 'mixed_positive' ? 90:190);
            $sample->('p2','present',185) if $case eq 'mixed_positive';
            GeoPresence_Timer($c);
        }
        is_deeply([grep {/^(?:door|garage) /} @commands],
            $case eq 'genuine_return' ? ['door lock unlocked']:[],
            "$case: a later actual return keeps the valid completion, a contradictory source cannot authorize opening");
    }
};

subtest 'delayed pre-start presence revokes only an older restored trip' => sub {
    for my $case (qw(restored newer_position older_presence new_trip)) {
        my ($c,$cfg,$s,$at,$sample,$base)=phone_timeline_fixture('state');
        $at->(50);$sample->($_,'absent',50) for qw(p1 p2);
        GeoPresence_Timer($c);$at->(70);process($s,$cfg,'Work',0);
        $at->(80);GP_Publish($c,'Geo.Test',$cfg,$s);my $id=$s->{trip}{id};
        $at->(100);delete $c->{helper}{gp};$mono=5;GP_ResetController($c,'resume');GeoPresence_Timer($c);
        $cfg=GP_Config($c,'Geo.Test');$s=GP_State($c,'Geo.Test',0);
        is($s->{resume}{status},'restored','qualified old trip restored against the available negative source');
        if ($case eq 'newer_position') {$at->(120);process($s,$cfg,'Checkpoint',1);}
        if ($case eq 'new_trip') {
            $at->(120);arrive($s,$cfg,'walking');$s->{intents}=[];
            $at->(130);process($s,$cfg,'Work',0);$id=$s->{trip}{id};
        }
        my $position=$s->{position_time};@commands=();
        $at->(150);$sample->('p1','present',$case eq 'older_presence' ? 60:90);GeoPresence_Timer($c);
        if ($case eq 'older_presence' || $case eq 'new_trip') {
            is(($s->{trip}//{})->{id},$id,'historical presence cannot override a later departure');
        } else {
            ok(!$s->{trip} && !$s->{arrival},'historical presence revoked the older restored authorization');
            is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none','revocation reached the checkpoint');
            cmp_ok($s->{position_time},'>=',$position,'historical presence did not rewind a newer position');
            $at->(200);http($c,form($cfg,'Home',1,$now,motion=>'automotive'));
            $at->(203);GeoPresence_Timer($c);$at->(264);GeoPresence_Timer($c);
        }
        is(scalar(grep {/^(?:door|garage) /} @commands),0,'historical presence creates no arrival action');
    }
};

subtest 'current presence cannot hide historical counterevidence to a restored trip' => sub {
    for my $case (qw(mixed three_positive older_presence new_trip)) {
        my ($c,$cfg,$s,$at,$sample,$base)=phone_timeline_fixture('state');
        my @sensors=qw(p1 p2);
        if ($case eq 'three_positive') {
            mode('GP','debug');attribute('Geo.Test','phoneProxies','p1,p2,p3');mode('GP','active');
            GeoPresence_Timer($c);$cfg=GP_Config($c,'Geo.Test');$s=GP_State($c,'Geo.Test',0);
            push @sensors,'p3';
        }
        $at->(50);$sample->($_,'absent',50) for @sensors;GeoPresence_Timer($c);
        $at->(70);process($s,$cfg,'Work',0);
        $at->(80);GP_Publish($c,'Geo.Test',$cfg,$s);
        $at->(100);delete $c->{helper}{gp};$mono=5;GP_ResetController($c,'resume');GeoPresence_Timer($c);
        $cfg=GP_Config($c,'Geo.Test');$s=GP_State($c,'Geo.Test',0);
        is($s->{resume}{status},'restored',"$case: independent Geo trip restored");
        if ($case eq 'new_trip') {
            $at->(120);arrive($s,$cfg,'walking');$s->{intents}=[];
            $at->(130);process($s,$cfg,'Work',0);
        }
        @commands=();$at->($case eq 'new_trip' ? 200:150);actor_fresh();
        $sample->('p1','present',$case eq 'older_presence' || $case eq 'three_positive' ? 60:90);
        $sample->('p2','present',$case eq 'new_trip' ? 200:150);
        $sample->('p3','present',90) if $case eq 'three_positive';
        GeoPresence_Timer($c);
        my $eligible=$case eq 'older_presence' || $case eq 'new_trip';
        is_deeply([grep {/^(?:door|garage) /} @commands],$eligible ? ['door lock unlocked','garage on']:[],
            "$case: historical counterevidence is independent of the latest positive sensor");
        if (!$eligible) {
            ok(!$s->{trip} && !$s->{arrival},'mixed observations revoked the old authorization');
            is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none',
                'revoked checkpoint cannot restore the trip again');
        }
    }
};

subtest 'a newer sensor cannot replace the actual return time within one session' => sub {
    for my $case (qw(combined_stale separate_stale fresh_early separate_early early_pending_home
        early_newer_position fresh_valid three_positive new_trip newer_position output_budget)) {
        my ($c,$cfg,$s,$at,$sample,$base)=phone_timeline_fixture('state');
        my @sensors=qw(p1 p2);
        if ($case eq 'three_positive') {
            mode('GP','debug');attribute('Geo.Test','phoneProxies','p1,p2,p3');mode('GP','active');
            GeoPresence_Timer($c);$cfg=GP_Config($c,'Geo.Test');$s=GP_State($c,'Geo.Test',0);
            push @sensors,'p3';
        }
        $at->(50);$sample->($_,'absent',50) for @sensors;GeoPresence_Timer($c);
        $at->(80);http($c,form($cfg,'Home',0,$now));GeoPresence_Timer($c);
        $at->(82);GeoPresence_Timer($c);$at->(85);GeoPresence_Timer($c);
        $at->(100);http($c,form($cfg,'Outer',0,$now));GeoPresence_Timer($c);
        $at->(102);GeoPresence_Timer($c);
        ok($s->{trip}{armed} && !$s->{trip}{phone_qualification},"$case: Geo independently confirmed the departure");
        if ($case eq 'new_trip') {
            $at->(150);process($s,$cfg,'Home',1,'walking');$s->{intents}=[];
            $at->(160);process($s,$cfg,'Work',0);
        } elsif ($case =~ /position/) {
            $at->($case eq 'newer_position' ? 200:160);process($s,$cfg,'Checkpoint',1);
        } elsif ($case eq 'early_pending_home') {
            $at->(165);process($s,$cfg,'Home',1,'walking');
            ok($s->{arrival},'newer Home return is waiting before the delayed short return arrives');
        }
        my $position=$s->{position_time};
        my $received=$case =~ /early/ ? 170:230;
        $at->($received-5);GeoPresence_Timer($c);
        $at->($received);actor_fresh();
        my $first=$case eq 'fresh_valid' || $case eq 'output_budget' ? 180:120;
        $sample->('p1','present',$case eq 'three_positive' ? 90:$first);
        if ($case !~ /^separate_/) {
            $sample->('p2','present',$case eq 'three_positive' ? 120:$received);
            $sample->('p3','present',$received) if $case eq 'three_positive';
        }
        $on_command=sub {advance(45) if $_[0] =~ /^door /;} if $case eq 'output_budget';
        GeoPresence_Timer($c);$on_command=undef;
        if ($case =~ /^separate_/) {
            $at->($received+5);$sample->('p2','present',$received+5);GeoPresence_Timer($c);
        }
        my $eligible=$case eq 'fresh_valid' || $case eq 'new_trip' || $case eq 'output_budget';
        my $expected=$eligible ? ['door lock unlocked',($case eq 'output_budget' ? ():'garage on')]:[];
        is_deeply([grep {/^(?:door|garage) /} @commands],$expected,
            "$case: decisions use the first relevant positive observation");
        ok(!$s->{trip} && !$s->{arrival},'the return consumed or revoked the old permission');
        is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none',
            'the old trip cannot be restored again');
        cmp_ok($s->{position_time},'>=',$position,'earlier return evidence did not rewind the known position');
        is(GP_ReadingTime('p1','presence'),$base+($case eq 'three_positive' ? 90:$first),
            'source observation time stayed unchanged');
        if (!$eligible) {
            $at->(300);http($c,form($cfg,'Home',1,$now,motion=>'walking'));
            $at->(303);GeoPresence_Timer($c);$at->(364);GeoPresence_Timer($c);
            is(scalar(grep {/^(?:door|garage) /} @commands),0,'later Home entry cannot reuse the old trip');
        }
    }
};

subtest 'current presence updates status without a trip despite older positive sources' => sub {
    for my $case (qw(state reverse three_positive measurement combined_no_trip)) {
        my $signal=$case eq 'measurement' ? 'measurement':'state';
        my ($c,$cfg,$s,$at,$sample,$base)=phone_timeline_fixture($signal);
        mode('GP','debug');
        attribute('Geo.Test','sourceMode','phone_only') unless $case eq 'combined_no_trip';
        my @sensors=$case eq 'three_positive' ? qw(p1 p2 p3):qw(p1 p2);
        attribute('Geo.Test','phoneProxies',join(',',@sensors));
        mode('GP','active');GeoPresence_Timer($c);
        $cfg=GP_Config($c,'Geo.Test');$s=GP_State($c,'Geo.Test',0);
        $defs{$_}{INTERVAL_NORMAL}=120 for @sensors;
        $at->(50);$sample->($_,'absent',50) for @sensors;GeoPresence_Timer($c);
        if ($signal eq 'measurement') {
            $at->(100);$sample->($_,'absent',100) for @sensors;GeoPresence_Timer($c);
        }
        $at->(225);GeoPresence_Timer($c);$at->(230);GeoPresence_Timer($c);
        ok(!$s->{trip} && !$s->{last_trip},"$case: status-only absence has no trip permission");
        is($s->{phase},'away','full absence window set GeoPresence away');
        is(GP_Read('rr_Test','state',''),'absent','full absence window set ROOMMATE absent');
        $at->(235);
        $sample->('p1','present',$case eq 'reverse' ? 235:120);
        $sample->('p2','present',$case eq 'reverse' ? 120:235);
        $sample->('p3','present',130) if $case eq 'three_positive';
        GeoPresence_Timer($c);
        is($s->{phone}{state},'present','healthy positive sources set phone presence');
        is($s->{phone}{latest},$base+235,'actual current positive observation remains visible');
        is($s->{phase},'home','current positive source also sets GeoPresence home');
        is(GP_Read('rr_Test','state',''),'home','current positive source also sets ROOMMATE home');
        is_deeply([map {GP_ReadingTime($_,'presence')} @sensors],
            [map {$base+$_} ($case eq 'reverse' ? (235,120):(120,235),$case eq 'three_positive' ? 130:())],
            'polling preserved every actual source date');
        for my $time (240,420) {
            $at->($time);GeoPresence_Timer($c);
            is($s->{phase},'home','home remains stable without another positive event');
            is(GP_Read('rr_Test','state',''),'home','ROOMMATE remains home without another positive event');
        }
        ok(!$s->{trip} && !$s->{last_trip} && !$s->{arrival},'status change created no trip or arrival permission');
        is(scalar(grep {/^(?:door|garage) /} @commands),0,'status change opened neither door nor garage');
    }
};

subtest 'a completed trip cannot hold later status changes to an old return' => sub {
    for my $case (qw(geo phone_qualified stale_old new_active)) {
        my ($c,$cfg,$s,$at,$sample,$base)=phone_timeline_fixture('state');
        $at->(50);$sample->($_,'absent',50) for qw(p1 p2);GeoPresence_Timer($c);
        $at->(80);http($c,form($cfg,'Home',0,$now));GeoPresence_Timer($c);
        $at->(82);GeoPresence_Timer($c);$at->(85);GeoPresence_Timer($c);
        if ($case eq 'phone_qualified') {
            $at->(265);GeoPresence_Timer($c);
            ok($s->{trip}{phone_qualification},'full phone absence qualified the first local trip');
        } else {
            $at->(100);http($c,form($cfg,'Outer',0,$now));GeoPresence_Timer($c);
            $at->(102);GeoPresence_Timer($c);
        }
        my $returned=$case eq 'phone_qualified' ? 300:200;
        $at->($returned);$sample->('p1','present',$returned);actor_fresh();GeoPresence_Timer($c);
        ok(!$s->{trip} && $s->{last_trip},"$case: first return completed the trip");
        is($s->{phase},'home','first return set GeoPresence home');
        my $old_trip=$s->{last_trip};
        my @old_bounds=@{$old_trip}{qw(id away_time away_mono)};
        my $old_intent=$c->{helper}{gp}{actors}{door}{intent};
        ok($old_intent,'the completed arrival had a real door output plan');
        my $old_expiry=$old_intent->{expires_mono};
        $at->($returned+1);
        reading('feedback','pulse_state','confirmed',$now);reading('gate','state','on',$now);
        reading('upper','state','closed',$now);reading('lower','state','open',$now);
        GeoPresence_Timer($c);@commands=();
        $at->($returned+70);$sample->($_,'absent',$returned+70) for qw(p1 p2);GeoPresence_Timer($c);
        $at->($returned+220);http($c,form($cfg,'Checkpoint',1,$now));
        $at->($returned+222);GeoPresence_Timer($c);
        my $position=$s->{position_time};
        $at->($returned+250);GeoPresence_Timer($c);
        ok(!$s->{trip},'later phone absence and nearby position created no new trip');
        is($s->{phase},'away','full later phone absence set GeoPresence away');
        is(GP_Read('rr_Test','state',''),'absent','full later phone absence set ROOMMATE absent');
        is($s->{position_time},$position,'held negatives did not rewind the nearby position');
        my $received=$returned+255;
        my $earlier=$case eq 'stale_old' ? 300:$returned+190;
        if ($case eq 'new_active') {
            $at->(470);http($c,form($cfg,'Work',0,$now));GeoPresence_Timer($c);
            $at->(472);GeoPresence_Timer($c);
            ok($s->{trip}{armed},'a genuinely new independent trip is active');
            ($earlier,$received)=(490,600);
        }
        $at->($received);$sample->('p1','present',$earlier);$sample->('p2','present',$received);
        my $source_dates=[map {GP_ReadingTime($_,'presence')} qw(p1 p2)];
        GeoPresence_Timer($c);
        is($s->{phone}{state},'present','both positive sources set current phone presence');
        if ($case eq 'new_active') {
            ok(!$s->{trip} && !$s->{arrival},'old positive evidence still revoked the active new trip');
        } else {
            is($s->{phase},'home','current presence set GeoPresence home despite the old trip');
            is(GP_Read('rr_Test','state',''),'home','current presence set ROOMMATE home');
            is($s->{position_time},$base+$received,'current status used its actual newer source date');
            is_deeply([@{$s->{last_trip}}{qw(id away_time away_mono)}],\@old_bounds,
                'status change did not renew the old trip identity or departure bounds');
            is($old_intent->{e}{time},$base+$returned,'old output retains its original return observation');
            is($old_intent->{expires_mono},$old_expiry,'current status did not renew the old output deadline');
            my @ready=GP_OutputReady($c,'Geo.Test',$cfg,$s,0,$old_intent);
            is(scalar @ready,0,'an old output plan remains blocked after the current status update');
            is($s->{last_reason},'intent expired','the old output is still checked against its own expired budget');
            ok(!$s->{trip} && !$s->{arrival},'status change created no new trip or arrival permission');
            for my $time ($received+5,$received+185) {
                $at->($time);GeoPresence_Timer($c);
                is($s->{phase},'home','home remains stable without another positive source event');
                is(GP_Read('rr_Test','state',''),'home','ROOMMATE remains home without another source event');
            }
        }
        is_deeply([map {GP_ReadingTime($_,'presence')} qw(p1 p2)],$source_dates,'source observation dates remain unchanged');
        is(scalar(grep {/^(?:door|garage) /} @commands),0,'later presence never replays an opening from the old trip');
        is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none',
            'the completed or revoked trip remains non-restorable');
    }
};

subtest 'additional negative samples do not move an already satisfied deadline' => sub {
    for my $case (qw(regular staggered state)) {
        my ($c,$cfg,$s,$at,$sample,$base)=phone_timeline_fixture(
            $case eq 'state' ? 'state':'measurement',phone_poll=>7);
        $defs{$_}{INTERVAL_NORMAL}=$case eq 'staggered' ? 120:7 for qw(p1 p2);
        my $base_mono=$mono;
        $at->(98);GeoPresence_Timer($c);
        $at->(100);http($c,form($cfg,'Home',0,$now));GeoPresence_Timer($c);
        $at->(102);GeoPresence_Timer($c);
        $at->(105);$sample->($_,'absent',105) for qw(p1 p2);GeoPresence_Timer($c);
        for (my $time=112;$time<=280;$time+=7) {
            $at->($time);$sample->('p1','absent',$time);
            $sample->('p2','absent',$time) unless $case eq 'staggered' && $time<280;
            GeoPresence_Timer($c) unless $case eq 'staggered' && $time==280;
        }
        $at->(286);actor_fresh();http($c,form($cfg,'Home',1,$now,motion=>'walking'));
        $at->(287);$sample->('p1','absent',287);
        $sample->('p2','absent',287) unless $case eq 'staggered';
        GeoPresence_Timer($c);
        my ($completion)=grep {$_->{kind} eq 'phone_absent'} @{$s->{queued_phones}};
        is($completion->{qualified_at},$base+285,"$case: extra measurements preserve the actual absolute completion");
        is($completion->{qualified_mono},$base_mono+285,"$case: extra measurements preserve the monotonic completion");
        $at->(288);GeoPresence_Timer($c);
        ok($s->{arrival},"$case: valid return before the next poll starts its normal arrival wait");
        $at->(347);GeoPresence_Timer($c);
        is_deeply([grep {/^(?:door|garage) /} @commands],['door lock unlocked'],
            "$case: the valid walking return opens only the door");
    }
};

subtest 'ordinary nearby observations do not consume a held absence completion' => sub {
    my ($c,$cfg,$s,$at,$sample,$base)=phone_timeline_fixture('state');
    $at->(50);$sample->($_,'absent',50) for qw(p1 p2);GeoPresence_Timer($c);
    $at->(100);http($c,form($cfg,'Home',0,$now));GeoPresence_Timer($c);$at->(102);GeoPresence_Timer($c);
    $at->(105);GeoPresence_Timer($c);my $since=$s->{phone}{negative_since};
    $at->(120);http($c,form($cfg,'Checkpoint',1,$now));$at->(122);GeoPresence_Timer($c);
    is($s->{position_time},$base+120,'nearby place advanced the position without independent distance evidence');
    ok(!$s->{trip}{armed},'nearby place did not authorize the trip');
    $at->(285);GeoPresence_Timer($c);
    ok($s->{trip}{armed},'full held absence still confirmed the local departure');
    is($s->{trip}{scope},'local','nearby place supplied no remote permission');
    is($s->{phone}{negative_since},$since,'nearby place did not restart the source interval');
    ok($s->{members}{'Z.Checkpoint'}{entry},'absence invented no explicit place exit');
    is(GP_ReadingTime('p1','presence'),$base+50,'held source timestamp stayed unchanged');
    $at->(300);actor_fresh();http($c,form($cfg,'Home',1,$now,motion=>'walking'));
    $at->(303);GeoPresence_Timer($c);$at->(361);GeoPresence_Timer($c);
    is_deeply([grep {/^(?:door|garage) /} @commands],['door lock unlocked'],'normal local return remained eligible');
};

subtest 'measurement completion bounds returns across batches and source types' => sub {
    for my $case (qw(same_batch separate_batch phone_counter after_deadline after_deadline_before_poll independent_geo)) {
        my ($c,$cfg,$s,$at,$sample,$base)=phone_timeline_fixture('measurement');
        $at->(100);http($c,form($cfg,'Home',0,$now));GeoPresence_Timer($c);$at->(102);GeoPresence_Timer($c);
        $at->(105);$sample->($_,'absent',105) for qw(p1 p2);GeoPresence_Timer($c);
        process($s,$cfg,'Work',0) if $case eq 'independent_geo';
        $at->(300);$sample->('p1','absent',300);GeoPresence_Timer($c);
        is(!!$s->{trip}{armed},$case eq 'independent_geo' ? 1:'','only independent Geo evidence can qualify before the source renewal');
        $at->(309);http($c,form($cfg,'Home',1,$base+305,motion=>'walking')) if $case eq 'same_batch';
        $at->(310);$sample->('p2','absent',310);
        GeoPresence_Timer($c) unless $case eq 'after_deadline_before_poll';
        if ($case eq 'phone_counter') {
            $at->(315);$sample->('p1','present',305);GeoPresence_Timer($c);
            ok(!$s->{trip},'late positive source observation contradicted the completed phone proof');
        } elsif ($case ne 'same_batch') {
            $at->(315);http($c,form($cfg,'Home',1,$base+($case eq 'separate_batch' || $case eq 'independent_geo' ? 305:315),motion=>'walking'));
        }
        $at->($case eq 'same_batch' ? 311:317);GeoPresence_Timer($c);
        my $eligible=$case =~ /^after_deadline/ || $case eq 'independent_geo';
        if ($eligible) {
            ok($s->{arrival},'actual return after the completed proof remained eligible before the next poll');
        } else {ok(!$s->{arrival},'return before the final required measurement cannot start an eligible arrival');}
        $at->(378);GeoPresence_Timer($c);
        is_deeply([grep {/^(?:door|garage) /} @commands],
            $eligible ? ['door lock unlocked']:[],
            "$case uses the same completion boundary");
        if ($case eq 'separate_batch') {
            $at->(390);actor_fresh();http($c,form($cfg,'Home',1,$now,motion=>'walking'));
            $at->(393);GeoPresence_Timer($c);$at->(451);GeoPresence_Timer($c);
            is(scalar(grep {/^(?:door|garage) /} @commands),0,'later Home entries cannot revive the already ended premature return');
        }
    }
};

subtest 'a later single positive measurement still updates phone-only status' => sub {
    my ($c,$cfg)=fixture();$cfg={%$cfg,sourceMode=>'phone_only',phoneSignalMode=>'measurement',proxies=>[qw(p1 p2)]};
    my $s=new_state();advance(105);my $samples=negative_samples();$samples->{$_}{ttl}=270 for keys %$samples;
    phone_tick($s,$cfg,$samples);advance(195);$samples->{p1}{time}=$now;phone_tick($s,$cfg,$samples);
    advance(10);$samples->{p2}{time}=$now;phone_tick($s,$cfg,$samples);
    is($s->{phase},'away','all renewed measurements confirmed status-only absence');
    advance(5);$samples->{p1}={value=>'present',time=>$now-10,ttl=>270,healthy=>1};phone_tick($s,$cfg,$samples);
    is($s->{phase},'home','one valid positive source wins even before the other source measurement');
    is(scalar @{$s->{intents}},0,'phone-only status never acquires an opening');
};

subtest 'delayed valid phone presence revokes a trip without allowing a stale arrival' => sub {
    for my $signal_mode (qw(state measurement)) {
        for my $pending (0,1) {
            my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}=$signal_mode;
            my $s=GP_State($c,'Geo.Test',0);advance(40);actor_fresh();
            process($s,$cfg,'Work',1);advance(1);phone_tick($s,$cfg,negative_samples());
            advance(180);phone_tick($s,$cfg,negative_samples());
            is($s->{phone}{state},'absent','phone absence was confirmed');
            advance(1);my $positive=negative_samples();$positive->{p1}{value}='present';
            my $observed=$now;
            if ($pending) {advance(1);process($s,$cfg,'Home',1,'walking');ok($s->{arrival},'Home return is waiting');}
            my $position=$s->{position_time};
            advance(100);my $event=phone_tick($s,$cfg,$positive);
            ok($event && $event->{arrival},"$signal_mode still recognizes the actual phone return");
            is($event->{time},$observed,'collector preserved the source observation time');
            ok(!$s->{trip},'late presence revoked the old trip');
            ok(!$s->{arrival} && !$s->{approach},'late presence cancelled all pending return evidence');
            cmp_ok($s->{position_time},'>=',$position,'revocation did not rewind a newer position');
            GP_ConfirmArrival($s,$cfg,$now,$mono);GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
            GP_Publish($c,'Geo.Test',$cfg,$s);
            is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none','revoked trip cannot resume');
            is(scalar(grep {/^(?:door|garage) /} @commands),0,'stale phone return did not open either actor');
            advance(1);arrive($s,$cfg,'automotive');GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
            is(scalar(grep {/^(?:door|garage) /} @commands),0,'fresh Home entry cannot reuse the revoked departure');
        }
    }
};

subtest 'status-only phone return clears distant membership for the next actual visit' => sub {
    my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}='state';my $s=new_state();advance(40);
    process($s,$cfg,'Work',1);advance(1);phone_tick($s,$cfg,negative_samples());
    advance(180);phone_tick($s,$cfg,negative_samples());
    advance(1);my $positive=negative_samples();$positive->{p1}{value}='present';
    advance(100);phone_tick($s,$cfg,$positive);
    is($s->{phase},'home','held presence synchronized Home without an arrival action');
    is(scalar @{$s->{intents}},0,'status-only return planned no action');
    advance(1);process($s,$cfg,'Home',0);advance(1);phone_tick($s,$cfg,negative_samples());
    advance(180);phone_tick($s,$cfg,negative_samples());advance(1);process($s,$cfg,'Work',1);
    is($s->{group_visits}{Work},2,'new actual Work visit was not suppressed by the prior trip membership');
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['notify'],'new visit still schedules its ordinary notification');
};

subtest 'older measurements, future and invalid phone samples cannot revoke a later trip' => sub {
    for my $case (qw(older_measurement future unhealthy expired_measurement)) {
        my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}=$case =~ /measurement/ ? 'measurement':'state';
        my $s=new_state();advance(40);my $positive=negative_samples();$positive->{p1}{value}='present';
        advance(1);process($s,$cfg,'Work',1);my $id=$s->{trip}{id};$s->{intents}=[];
        if ($case eq 'future') {$positive->{p1}{time}=$now+10;}
        elsif ($case eq 'unhealthy') {$positive->{p1}{healthy}=0;}
        elsif ($case eq 'expired_measurement') {advance(200);}
        else {advance(100);}
        phone_tick($s,$cfg,$positive);
        is(($s->{trip}//{})->{id},$id,"$case sample preserved the later departure");
        is(scalar @{$s->{intents}},0,'sample created no action');
    }
};

subtest 'discovering held presence after Geo departure applies the same veto as before departure' => sub {
    for my $delay (80,100) {
        my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}='state';my $s=new_state();
        advance(40);my $held=negative_samples();$held->{p1}{value}='present';
        advance(1);process($s,$cfg,'Work',1);$s->{intents}=[];
        advance($delay);phone_tick($s,$cfg,$held);
        ok(!$s->{trip},'still-valid held presence revoked the Geo departure even with an earlier observation date');
        is(scalar @{$s->{intents}},0,'earlier held presence could not become a new arrival');
        advance(1);arrive($s,$cfg,'automotive');
        is(scalar @{$s->{intents}},0,'later Home entry could not reuse the contradicted departure');
    }
};

subtest 'held presence observed before an unconfirmed Home exit preserves the departure suspicion' => sub {
    for my $delay (80,100) {
        my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}='state';my $s=new_state();advance(40);
        my $positive=negative_samples();$positive->{p1}{value}='present';
        advance(1);process($s,$cfg,'Home',0);my $id=$s->{trip}{id};
        advance($delay);phone_tick($s,$cfg,$positive);
        is(($s->{trip}//{})->{id},$id,'older held presence preserved the later unconfirmed Home exit');
        ok(!$s->{trip}{armed},'held presence did not authorize it');
        advance(1);my $held=negative_samples();phone_tick($s,$cfg,$held);
        advance(180);phone_tick($s,$cfg,$held);
        ok($s->{trip}{armed},'actual negative transition and a full new interval still qualify this departure');
        advance(1);arrive($s,$cfg,'walking');
        is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'legitimate later walk retains its door permission');
    }
};

subtest 'held negatives before Home exit start a new full interval without another measurement' => sub {
    for my $already_qualified (0,1) {
        my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}='state';
        my $s=GP_State($c,'Geo.Test',0);advance(40);actor_fresh();
        my $held=negative_samples();my $source_time=$now;
        phone_tick($s,$cfg,$held);
        if ($already_qualified) {advance(180);phone_tick($s,$cfg,$held);ok($s->{phone}{qualified},'earlier absence was qualified');}
        advance(10);process($s,$cfg,'Home',0);my $exit=$now;
        phone_tick($s,$cfg,$held);my $since=$s->{phone}{negative_since};
        ok(defined($since),'unchanged valid negatives started a new qualification after Home exit');
        ok(!$s->{trip}{armed},'Home exit did not reuse the previous interval');
        advance(179);phone_tick($s,$cfg,$held);
        ok(!$s->{trip}{armed},'179 seconds of the new interval are not enough');
        advance(1);my $event=phone_tick($s,$cfg,$held);
        ok($event && $event->{kind} eq 'phone_absent','full interval produced a qualified absence');
        is(($event//{})->{time},$source_time,'source timestamp was not replaced by a poll time');
        ok($s->{trip}{armed},'maintained absence confirmed the new Home departure');
        is($s->{trip}{scope},'local','phone evidence did not create remote scope');
        is($s->{trip}{away_time},$exit,'departure evidence began with the new interval');
        is($s->{position_time},$exit,'older held observations did not rewind the Home exit');
        is_deeply([map {$held->{$_}{time}} sort keys %$held],[($source_time)x3],'no sensor timestamp was refreshed');
        advance(1);arrive($s,$cfg,'walking');GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
        is_deeply([grep {/^(?:door|garage) /} @commands],['door lock unlocked'],'qualified local walk opens only the door');
    }
};

subtest 'a Home exit revokes a collected absence and measurement sources still need new observations' => sub {
    for my $signal_mode (qw(state measurement)) {
        my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}=$signal_mode;
        my $s=new_state();advance(40);my $held=negative_samples();phone_tick($s,$cfg,$held);
        advance(180);$held=negative_samples() if $signal_mode eq 'measurement';
        my $old=GP_Phone($s,$cfg,$held,$now,$mono);ok($old,'absence was collected before departure');
        advance(10);process($s,$cfg,'Home',0);
        GP_Process($s,$cfg,$old,$now,$mono);
        ok(!$s->{trip}{armed},'collected old event cannot authorize the new trip');
        phone_tick($s,$cfg,$held);advance(180);phone_tick($s,$cfg,$held);
        if ($signal_mode eq 'state') {ok($s->{trip}{armed},'new held-state interval can qualify');}
        else {
            ok(!$s->{trip}{armed},'old measurements cannot qualify after the Home exit');
            advance(1);phone_tick($s,$cfg,negative_samples());
            advance(179);phone_tick($s,$cfg,negative_samples());ok(!$s->{trip}{armed},'new measurements need the full interval');
            advance(1);phone_tick($s,$cfg,negative_samples());ok($s->{trip}{armed},'renewed measurements still qualify normally');
        }
    }
};

subtest 'production and live debug read one immutable phone snapshot per timer' => sub {
    my ($c,$cfg)=fixture();my $prod=GP_State($c,'Geo.Test',0);my $debug=GP_State($c,'Geo.Test',1);
    advance(40);my $samples=negative_samples();$samples->{p1}{value}='present';
    my $raw=JSON::PP::encode_json($samples);my $reads=0;
    no warnings qw(redefine once);
    local *GP_PhoneSamples=sub {$reads++;return $samples;};
    GeoPresence_Timer($c);
    is($reads,1,'both due contexts shared one source read');
    is($prod->{phone}{state},'present','production processed the source');
    is($debug->{phone}{state},'present','live debug processed the same source');
    isnt($prod->{phone},$debug->{phone},'phone continuity belongs to each context');
    is(JSON::PP::encode_json($samples),$raw,'neither context mutated the shared snapshot');
    advance(5);GeoPresence_Timer($c);is($reads,2,'next due poll read the sources only once again');
    $debug->{phone_mode}='simulated';$debug->{sim_phone}='absent';
    advance(5);GeoPresence_Timer($c);is($reads,3,'simulated debug did not add a live-source read');
    ok(defined($debug->{phone}{negative_since}) && !defined($prod->{phone}{negative_since}),
        'simulated debug qualification did not change production continuity');
};

subtest 'a later completed absence cannot retroactively authorize an earlier Home entry' => sub {
    for my $negative_before_exit (0,1) {
        for my $return (qw(before_deadline future_date late_observation after_deadline)) {
            my ($c)=fixture();mode('GP','debug');attribute('Geo.Test','phoneSignalMode','state');
            mode('GP','active');GeoPresence_Timer($c);
            my $cfg=GP_Config($c,'Geo.Test');my $s=GP_State($c,'Geo.Test',0);
            my $sensors=sub {
                for my $name (qw(p1 p2 p3)) {
                    my $value=$name eq 'p1' && $_[0] ? 'present':'absent';
                    reading($name,'state',$value,$now);reading($name,'presence',$value,$now);
                }
            };
            advance(40);actor_fresh();$sensors->(!$negative_before_exit);GeoPresence_Timer($c);
            advance(10);http($c,form($cfg,'Home',0,$now));advance(3);GeoPresence_Timer($c);
            advance(5);$sensors->(0) unless $negative_before_exit;GeoPresence_Timer($c);
            my $since=$s->{phone}{negative_since};ok(defined($since),'new absence interval is running');
            advance($return eq 'before_deadline' ? 100:$return eq 'after_deadline' ? 181:170);
            my $body=form($cfg,'Home',1,$now+($return eq 'future_date' ? 20:0),motion=>'walking');
            if ($return eq 'late_observation') {advance(10);GeoPresence_Timer($c);}
            http($c,$body);
            advance($return eq 'after_deadline' || $return eq 'late_observation' ? 3:180-($mono-$since));
            GeoPresence_Timer($c);
            if ($return eq 'after_deadline') {
                ok($s->{trip}{armed} && $s->{arrival},'return after the actual deadline stays eligible even before the next poll');
            } else {ok(!$s->{arrival},"$return cannot acquire a later absence confirmation");}
            is(scalar(grep {/^(?:door|garage) /} @commands),0,'no premature actor command');
            advance(61);GeoPresence_Timer($c);
            is_deeply([grep {/^(?:door|garage) /} @commands],$return eq 'after_deadline' ? ['door lock unlocked']:[],
                "$return: only a return after the full window can open");
        }
    }
};

subtest 'a fresh but delayed phone return must follow its full absence window' => sub {
    my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}='state';my $s=new_state();advance(40);
    process($s,$cfg,'Home',0);advance(1);my $negative=negative_samples();phone_tick($s,$cfg,$negative);
    advance(170);my $positive=negative_samples();$positive->{p1}{value}='present';
    advance(10);phone_tick($s,$cfg,$negative);ok($s->{trip}{armed},'absence confirmation was processed first');
    advance(1);my $event=phone_tick($s,$cfg,$positive);
    ok($event && $event->{arrival},'delayed actual phone return remained fresh');
    ok(!$s->{trip} && !$s->{arrival},'return observed before the full window closed the outing');
    is(scalar @{$s->{intents}},0,'late processing did not grant that early return an opening');
};

subtest 'state-only sensors qualify absence without periodic repeat messages' => sub {
    for my $walk (0,1) {
        my ($c,$cfg)=fixture();$cfg->{sourceMode}='phone_only' unless $walk;
        $cfg->{phoneSignalMode}='state';
        my $s=new_state();advance(40);
        process($s,$cfg,'Home',0) if $walk;
        advance(1);my $held=negative_samples();phone_tick($s,$cfg,$held);
        advance(179);phone_tick($s,$cfg,$held);ok(!$s->{phone}{qualified},'not qualified before full interval');
        advance(1);phone_tick($s,$cfg,$held);
        is($s->{phone}{state},'absent','one unchanged negative state from every room is sufficient');
        is($s->{desired_status},'absent','phone_only and geofency users can become absent');
        if ($walk) {
            ok($s->{trip}{armed},'Home exit plus maintained negative house state qualifies local walk');
            advance(1);arrive($s,$cfg);
            is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'local walk opens only door');
        } else {
            advance(600);phone_tick($s,$cfg,$held);
            is($s->{phone}{state},'absent','latched negatives do not expire at 150 or 270 seconds');
            ok(!$s->{trip},'phone-only absence creates no opening permission');
        }
    }
};

subtest 'state snapshots synchronize after restart without manufacturing arrival evidence' => sub {
    my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}='state';
    my $old=negative_samples();advance(3600);my $s=new_state();
    my $positive={map {$_=>{%{$old->{$_}}}} keys %$old};$positive->{p1}{value}='present';
    my $e=phone_tick($s,$cfg,$positive);
    is($e->{kind},'phone_snapshot','old held positive is explicitly a snapshot');
    is($s->{desired_status},'home','snapshot can synchronize presence');
    is(scalar @{$s->{intents}},0,'snapshot never opens');
    advance(600);ok(!phone_tick($s,$cfg,$positive),'held present does not become a new arrival or expire');
    is($s->{phone}{health},'held','held is distinguishable from a fresh measurement');
    $s=new_state();phone_tick($s,$cfg,$old);advance(180);phone_tick($s,$cfg,$old);
    is($s->{desired_status},'absent','old consistent negative snapshots can synchronize phone_only status after grace');
    ok(!$s->{trip},'baseline absence cannot create a trip');
    advance(40);process($s,$cfg,'Home',0);advance(1);phone_tick($s,$cfg,$old);
    advance(180);phone_tick($s,$cfg,$old);
    ok(!$s->{trip}{armed},'new Home exit cannot reuse pre-start negative snapshots as opening evidence');
    advance(1);$old->{p1}{time}=$now;phone_tick($s,$cfg,$old);
    advance(180);phone_tick($s,$cfg,$old);
    ok($s->{trip}{armed},'a new last-room negative observation qualifies with unchanged negatives from other rooms');
};

subtest 'held source faults invalidate old samples and restart the full absence interval' => sub {
    my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}='state';my $s=new_state();advance(40);
    process($s,$cfg,'Home',0);advance(1);my $held=negative_samples();phone_tick($s,$cfg,$held);
    advance(120);$held->{p2}{healthy}=0;phone_tick($s,$cfg,$held);
    ok(!defined $s->{phone}{negative_since},'explicit error interrupts qualification without using a TTL');
    advance(1);$held->{p2}{healthy}=1;phone_tick($s,$cfg,$held);
    advance(180);phone_tick($s,$cfg,$held);
    ok(!$s->{trip}{armed},'connection recovery alone does not restore invalidated negative');
    advance(1);$held->{p2}{time}=$now;phone_tick($s,$cfg,$held);
    advance(179);phone_tick($s,$cfg,$held);ok(!$s->{trip}{armed},'new observation starts a complete 180 s interval');
    advance(1);phone_tick($s,$cfg,$held);ok($s->{trip}{armed},'new observation and stable coverage requalify');
};

subtest 'qualified phone absence still detects faults and requires a full renewed interval' => sub {
    for my $signal (qw(state measurement)) {
        my ($c,$cfg)=fixture();$cfg->{sourceMode}='phone_only';$cfg->{phoneSignalMode}=$signal;
        my $s=new_state();advance(40);my $samples=negative_samples();phone_tick($s,$cfg,$samples);
        advance(90);$samples=negative_samples() if $signal eq 'measurement';phone_tick($s,$cfg,$samples);
        advance(90);phone_tick($s,$cfg,$samples);
        ok($s->{phone}{qualified},"$signal: full renewed interval qualified absence");
        advance(5);ok(!phone_tick($s,$cfg,$samples),'continued qualified absence emits no second event');
        is($s->{phone}{state},'absent','healthy unchanged negatives retain absence');
        is($s->{phone}{health},$signal eq 'state' ? 'held':'fresh','healthy unchanged negatives retain source health');
        advance(1);$samples->{p2}{healthy}=0;phone_tick($s,$cfg,$samples);
        ok(!$s->{phone}{qualified},'source fault invalidates an already completed qualification');
        is($s->{phone}{health},'unknown','fault remains visible after prior qualification');
        advance(1);$samples->{p2}{healthy}=1;phone_tick($s,$cfg,$samples);
        advance(180);phone_tick($s,$cfg,$samples);
        ok(!$s->{phone}{qualified},'recovery with old observations cannot restore qualification');
        advance(1);$samples=negative_samples();phone_tick($s,$cfg,$samples);
        advance(90);$samples=negative_samples();phone_tick($s,$cfg,$samples);
        advance(89);phone_tick($s,$cfg,$samples);
        ok(!$s->{phone}{qualified},'179 seconds of the new interval are insufficient');
        advance(1);my $event=phone_tick($s,$cfg,$samples);
        ok($event && $s->{phone}{qualified},'new observations and the full interval requalify absence');
        is(scalar @{$s->{intents}},0,'status-only qualification grants no action');
    }
};

subtest 'negative events are ordered and cannot survive an arrival or a clock reset' => sub {
    my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}='state';my $s=new_state();advance(40);
    process($s,$cfg,'Home',0);advance(1);my $held=negative_samples();phone_tick($s,$cfg,$held);
    advance(180);my $negative=GP_Phone($s,$cfg,$held,$now,$mono);
    is($s->{phase},'leaving','collector does not mutate phase while a geo batch is pending');
    ok(!$s->{trip}{armed},'collector does not grant an opening outside ordered processing');
    advance(1);my $positive=negative_samples();$positive->{p1}{value}='present';
    my $arrival=GP_Phone($s,$cfg,$positive,$now,$mono);
    GP_Process($s,$cfg,$negative,$now,$mono);
    ok($s->{trip}{armed},'earlier qualified absence is processed before later phone return');
    GP_Process($s,$cfg,$arrival,$now,$mono);
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'ordered phone return completes the local walk');
    GP_Process($s,$cfg,$negative,$now,$mono);
    is($s->{phase},'home','completed arrival revokes the old negative event');
    advance(1);$s=new_state();GP_Process($s,$cfg,$negative,$now,$mono);
    is($s->{phase},'unknown','new session does not accept old qualified event');
    $s=new_state();advance(40);phone_tick($s,$cfg,negative_samples());advance(180);
    $negative=GP_Phone($s,$cfg,negative_samples(),$now,$mono);
    $now+=3600;GP_Process($s,$cfg,$negative,$now,$mono);
    is($s->{phase},'unknown','clock discontinuity revokes already collected absence');
};

subtest 'a new negative phase after arrival remains usable without recycling old values' => sub {
    my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}='state';my $s=new_state();advance(40);
    process($s,$cfg,'Home',0);advance(1);my $held=negative_samples();phone_tick($s,$cfg,$held);
    advance(180);phone_tick($s,$cfg,$held);advance(1);arrive($s,$cfg);
    advance(120);phone_tick($s,$cfg,$held);is($s->{phase},'home','old negatives cannot start another interval');
    advance(1);$held->{p2}{time}=$now;phone_tick($s,$cfg,$held);
    advance(179);phone_tick($s,$cfg,$held);is($s->{phase},'home','new absence waits for its own interval');
    advance(1);phone_tick($s,$cfg,$held);is($s->{phase},'away','new negative state can change status after full interval');
    ok(!$s->{trip},'status correction alone has no opening permission');
};

subtest 'held positive state vetoes remote evidence until the room actually changes state' => sub {
    my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}='state';my $s=new_state();advance(40);
    my $held=negative_samples();$held->{p1}{value}='present';phone_tick($s,$cfg,$held);
    advance(600);phone_tick($s,$cfg,$held);process($s,$cfg,'Outer',0);
    ok(!$s->{trip},'unchanged positive house state rejects remote evidence despite old timestamp');
    is($s->{phase},'home','held presence remains authoritative');
    advance(10);process($s,$cfg,'Home',0);
    advance(1);$held->{p1}={value=>'absent',time=>$now,healthy=>1,ttl=>150};phone_tick($s,$cfg,$held);
    advance(180);phone_tick($s,$cfg,$held);
    ok($s->{trip}{armed},'real last-room transition qualifies a subsequent walk');
    is($s->{trip}{scope},'local','held presence rejection cannot contaminate scope');
};

subtest 'manual home also revokes previously qualified phone absence' => sub {
    my ($c,$cfg)=fixture();$cfg->{phoneSignalMode}='state';
    my $s=GP_State($c,'Geo.Test',0);advance(40);my $held=negative_samples();
    phone_tick($s,$cfg,$held);advance(180);phone_tick($s,$cfg,$held);
    GP_Publish($c,'Geo.Test',$cfg,$s);is(GP_Read('rr_Test','state',''),'absent','phone status initially absent');
    advance(1);reading('rr_Test','state','home',$now);
    $defs{rr_Test}{CHANGED}=['home'];GeoPresence_Notify($c,$defs{rr_Test});
    advance(5);phone_tick($s,$cfg,$held);GP_Publish($c,'Geo.Test',$cfg,$s);
    is(GP_Read('rr_Test','state',''),'home','manual home is not undone by the same negative observations');
    ok(!$s->{phone}{qualified},'manual synchronization starts a new evidence boundary');
};

subtest 'DriveIn is optional for jitter protection, walks, remote trips and phone arrival' => sub {
    my ($c)=fixture();
    delete $defs{'Z.Drive'}; delete $attr{'Z.Drive'}; delete $defs{'R.Early'}; delete $attr{'R.Early'};
    config_event('DELETED Z.Drive','DELETED R.Early');
    GP_ResetController($c);GeoPresence_Timer($c);my $cfg=GP_Config($c,'Geo.Test');
    is_deeply([GP_Validate($c,'Geo.Test',1)],[],'Home and outer validate without approach');
    my $s=new_state();advance(40);process($s,$cfg,'Home',0);advance(90);arrive($s,$cfg);
    is(scalar @{$s->{intents}},0,'Home jitter alone never opens');
    $s=new_state();$cfg->{phoneSignalMode}='state';advance(40);process($s,$cfg,'Home',0);advance(1);
    my $absent=negative_samples();phone_tick($s,$cfg,$absent);advance(180);phone_tick($s,$cfg,$absent);
    advance(1);arrive($s,$cfg);
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'qualified local walk opens only door');
    $s=new_state();advance(40);process($s,$cfg,'Work',0);advance(90);arrive($s,$cfg);
    is_deeply([sort map {$_->{kind}} @{$s->{intents}}],[qw(door_open garage_open)],'remote return opens on Home without DriveIn');
    $s=new_state();advance(40);process($s,$cfg,'Outer',0);advance(1);phone_tick($s,$cfg,negative_samples());
    advance(180);phone_tick($s,$cfg,negative_samples());advance(1);my $present=negative_samples();$present->{p2}{value}='present';
    phone_tick($s,$cfg,$present);
    is_deeply([sort map {$_->{kind}} @{$s->{intents}}],[qw(door_open garage_open)],'phone fallback needs no DriveIn or Home arrival');
    $s=new_state();advance(40);$cfg->{zones}{'Z.Checkpoint'}{lat}=0.002;
    process($s,$cfg,'Checkpoint',1);ok(!$s->{trip},'nearby circle does not count as distant evidence');
};

subtest 'learning works before location registration and returns safe manual commands only' => sub {
    my ($c,$cfg)=fixture();mode('GP','debug');
    for my $n (grep {/^Z\./} keys %defs) {delete $defs{$n};delete $attr{$n};config_event("DELETED $n");}
    GP_ResetController($c);GeoPresence_Timer($c);advance(40);
    my @before=sort keys %defs;my $before_calls=$reading_calls;
    like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','mode','learning'),qr/Learning for 15/,'explicit learning starts without locations');
    my $body=form($cfg,'Home',1,$now,name=>'Home');
    is_deeply([http($c,$body)],[200,'OK ignored during learning; isTest=true required; no actions'],'real observation cannot enroll a location');
    is((http($c,$body,1,'Basic '.encode_base64('user:wrong','')))[0],401,'learning requires authentication');
    is((http($c,form($cfg,'Home',1,$now,device=>'OTHER'),1))[0],422,'device binding also applies during learning');
    is((http($c,$body,1))[0],200,'unregistered location learned with isTest=true');
    my $learned_text=GeoPresence_Get($c,'GP','learnedLocations','Geo.Test','format=json');
    my $learned=JSON::PP::decode_json($learned_text);
    is($learned->[0]{id},'home','received ID available');is($learned->[0]{name},'Home','received name available');
    like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','learnConfirm'),qr/Learning confirmed/,'confirm captured metadata before generating definitions');
    my $text=GeoPresence_Get($c,'GP','locationCommands','Geo.Test','@1','home','New.Home');
    is($text,"define New.Home GeoPresence location Geo.Test home\nattr New.Home zoneId home",'number produces exact manual definitions without geometry');
    like(GeoPresence_Get($c,'GP','locationCommands','Geo.Test','@1','home','New.Home;set'),qr/Usage:/,'command injection in device name rejected');
    like(GeoPresence_Get($c,'GP','locationCommands','Geo.Test','other-id','home','New.Home'),qr/not observed/,'known export ID must match this resident capture');
    is_deeply([sort keys %defs],\@before,'learning and command generation create no devices');
    is($reading_calls,$before_calls,'zero reading API calls');is(scalar @commands,0,'zero status or actuator commands');is(scalar @messages,0,'zero notifications');
    is(scalar @{$c->{helper}{gp}{queue}},0,'learning is not a simulated trip');
    advance(901);
    is(GeoPresence_Get($c,'GP','learnedLocations','Geo.Test','format=json'),$learned_text,
        'captured results remain available after the reception window expires');
    is(GeoPresence_Get($c,'GP','locationCommands','Geo.Test','@1','home','New.Home'),$text,
        'manual commands remain available after reception expires');
    is((http($c,form($cfg,'Home',1,$now),1))[0],503,'expired learning does not become normal execution');
    is(GeoPresence_Get($c,'GP','learnedLocations','Geo.Test','format=json'),$learned_text,
        'expired reception does not update retained results');
    is($reading_calls,$before_calls,'retained results do not publish readings');
    is(scalar @commands,0,'retained results do not dispatch commands');
    is(scalar @messages,0,'retained results do not send notifications');
};

subtest 'stopped learning survives slow manual setup and reload but stays bound to its resident and phone' => sub {
    my ($c,$cfg)=fixture();mode('GP','debug');GeoPresence_Timer($c);advance(40);
    my $before_calls=$reading_calls;
    GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','mode','learning');
    is((http($c,form($cfg,'Home',1,$now,name=>'Home'),1))[0],200,'Home captured');
    my $learned=GeoPresence_Get($c,'GP','learnedLocations','Geo.Test','format=json');
    like(GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','learnConfirm'),qr/Learning confirmed/,'capture explicitly confirmed');
    advance(901);GeoPresence_Timer($c);
    is(GeoPresence_Get($c,'GP','learnedLocations','Geo.Test','format=json'),$learned,'stopped results still visible after fifteen minutes');
    is((http($c,form($cfg,'Home',1,$now,id=>'unregistered'),1))[0],503,
        'retaining results does not authorize learning more locations');
    is(GeoPresence_Get($c,'GP','locationCommands','Geo.Test','HOME','home','New.Home'),
        "define New.Home GeoPresence location Geo.Test home\nattr New.Home zoneId home",
        'known ID in uppercase still produces manual commands after learnStop and expiry');
    gp_define('New.Home','location Geo.Test home');attribute('New.Home','zoneId','home');
    is(GeoPresence_Get($c,'GP','learnedLocations','Geo.Test','format=json'),$learned,'defining and configuring a location keeps results');
    GeoPresence_Initialize({});GeoPresence_Timer($c);
    is(GeoPresence_Get($c,'GP','learnedLocations','Geo.Test','format=json'),$learned,'module reload initialization retains even expired results');
    ok(!$c->{helper}{gp}{learning}{'Geo.Test'},'reload does not reopen reception');
    is($reading_calls,$before_calls,'debug setup and result retrieval cause no Reading callbacks');
    is(scalar @commands,0,'debug setup dispatches no commands');
    is(scalar @messages,0,'debug setup sends no notifications');

    GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','mode','learning');
    is(GeoPresence_Get($c,'GP','learnedLocations','Geo.Test','format=json'),'[]','new learnStart explicitly replaces the result list');
    advance(1);
    is((http($c,form($cfg,'Work',1,$now,name=>'Work'),1))[0],200,'new window receives new results');
    my $replacement=JSON::PP::decode_json(GeoPresence_Get($c,'GP','learnedLocations','Geo.Test','format=json'));
    is_deeply([map {$_->{id}} @$replacement],['work'],'old session locations are absent');
    is($replacement->[0]{number},1,'new session starts numbering again');
    like(GeoPresence_Attr('set','Geo.Test','deviceId','invalid;id'),qr/Invalid/,'invalid identity change rejected');
    GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','learnConfirm');
    attribute('Geo.Test','deviceId','device');
    ok(GP_Learned($c,'Geo.Test'),'same identity with different case retains the list');
    attribute('Geo.Test','deviceId','OTHER');
    like(GeoPresence_Get($c,'GP','learnedLocations','Geo.Test','format=json'),qr/No current learning data/,'different phone cannot see old results');
    attribute('Geo.Test','deviceId','DEVICE');
    ok(!GP_Learned($c,'Geo.Test'),'changing identity back does not revive discarded results');

    GeoPresence_Timer($c);GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','mode','learning');advance(1);
    http($c,form($cfg,'Home',1,$now),1);
    GeoPresence_Undef($defs{'Geo.Test'});
    ok(!exists $c->{helper}{gp}{learned}{'Geo.Test'},'removing resident clears retained results');
    GeoPresence_Set($defs{'Geo.Test'},'Geo.Test','mode','learning');
    delete $c->{helper}{gp};GP_ResetController($c);
    ok(!GP_Learned($c,'Geo.Test'),'new process state cannot restore learned debug data');
};

subtest 'first geometry observations synchronize only and debug never supplies productive geometry' => sub {
    my ($c,$cfg)=fixture();
    delete $defs{$_}{READINGS}{gp_geometry} for grep {/^Z\./} keys %defs;
    GP_ResetController($c);GeoPresence_Timer($c);advance(40);
    like(GeoPresence_Get($c,'GP','validate','Geo.Test'),qr/Opening unavailable/,'structure valid while geometry pending');
    my $calls=$reading_calls;
    for my $z (qw(Home Outer Work Drive)) {http($c,form($cfg,$z,1,$now),1);advance(3);GeoPresence_Timer($c);}
    ok(GP_Config($c,'Geo.Test',1)->{geometry_ready},'debug learns core geometry automatically');
    ok(!GP_Config($c,'Geo.Test',0)->{geometry_ready},'production remains uninitialized');
    is($reading_calls,$calls,'debug geometry causes no reading callbacks');
    advance(40);http($c,form($cfg,'Work',0,$now),1);advance(3);GeoPresence_Timer($c);
    ok(GP_State($c,'Geo.Test',1)->{trip}{armed},'later debug journey can use its own geometry');
    GeoPresence_Set($c,'GP','debugReset','Geo.Test');
    ok(!GP_Config($c,'Geo.Test',1)->{geometry_ready},'debug reset discards unsaved simulated geometry');
    for my $z (qw(Home Outer Work Drive)) {http($c,form($cfg,$z,1,$now));advance(3);GeoPresence_Timer($c);}
    ok(GP_Config($c,'Geo.Test',0)->{geometry_ready},'real webhooks initialize productive geometry');
    ok(!GP_State($c,'Geo.Test',0)->{trip},'initial registration cannot arm');
    is(scalar(grep {/^(?:door|garage) /} @commands),0,'initial observations never open');
};

subtest 'geometry changes cancel an entire pending batch in either delivery order' => sub {
    for my $reverse (0,1) {
        my ($c,$cfg)=fixture();advance(40);http($c,form($cfg,'Work',0,$now));advance(3);GeoPresence_Timer($c);
        advance(90);actor_fresh();my @payload=(form($cfg,'Home',1,$now),form($cfg,'Work',1,$now+1,radius=>110));
        @payload=reverse @payload if $reverse;
        http($c,$_) for @payload;advance(4);GeoPresence_Timer($c);
        is(scalar(grep {/^(?:door|garage) /} @commands),0,"pending arrival cancelled, reverse=$reverse");
        ok(!GP_State($c,'Geo.Test',0)->{trip},'old remote permission removed');
        is(GP_Config($c,'Geo.Test')->{zones}{'Z.Work'}{radius},110,'new radius adopted');
    }
};

subtest 'equal-time conflicting geometry stays blocked until a newer consistent observation' => sub {
    my ($c,$cfg)=fixture();advance(40);
    http($c,form($cfg,'Home',1,$now,radius=>55));http($c,form($cfg,'Home',1,$now,radius=>60));
    advance(3);GeoPresence_Timer($c);
    ok(!GP_Config($c,'Geo.Test')->{geometry_ready},'ambiguous geometry blocks opening');
    GP_ResetController($c);GeoPresence_Timer($c);
    ok(!GP_Config($c,'Geo.Test')->{geometry_ready},'conflict survives reload via ordinary readings');
    advance(40);http($c,form($cfg,'Home',1,$now,radius=>60));advance(3);GeoPresence_Timer($c);
    ok(GP_Config($c,'Geo.Test')->{geometry_ready},'fresh unambiguous geometry recovers automatically');
    ok(!GP_State($c,'Geo.Test',0)->{trip},'recovery cannot arm');
};

subtest 'invalid nesting and stale geometry do not poison or authorize the current journey' => sub {
    my ($c,$cfg)=fixture();advance(40);
    http($c,form($cfg,'Home',1,$now,radius=>5000));advance(3);GeoPresence_Timer($c);
    ok(!GP_Config($c,'Geo.Test')->{geometry_ready},'invalid nesting blocks opening but can receive fixes');
    advance(1);http($c,form($cfg,'Home',1,$now));advance(3);GeoPresence_Timer($c);
    ok(GP_Config($c,'Geo.Test')->{geometry_ready},'phone correction restores geometry');
    advance(1);http($c,form($cfg,'Work',0,$now));advance(3);GeoPresence_Timer($c);
    ok(GP_State($c,'Geo.Test',0)->{trip}{armed},'fresh departure usable after correction');
    http($c,form($cfg,'Home',0,$now-1000,radius=>10000));advance(3);GeoPresence_Timer($c);
    is(GP_Config($c,'Geo.Test')->{zones}{'Z.Home'}{radius},50,'stale radius ignored');
    ok(GP_State($c,'Geo.Test',0)->{trip}{armed},'stale geometry cannot invalidate a current trip');
};

subtest 'idle timer reuses configuration and still detects changed activation guards' => sub {
    my ($c)=fixture();
    for (1..808) {device("Idle.Unrelated.$_",'dummy');}
    $defs{GP}{READINGS}{mode}{VAL}='debug';$attr{GP}{verbose}=5;
    GP_ResetController($c);GeoPresence_Timer($c);
    my $builds=0;my $validations=0;
    my $build=\&GP_Config;my $validate=\&GP_Validate;
    {
        no warnings 'redefine';
        local *GP_Config=sub {$builds++;return $build->(@_)};
        local *GP_Validate=sub {$validations++;return $validate->(@_)};
        for (1..10) {advance(1);GeoPresence_Timer($c);}
    }
    is($builds,10,'one prepared configuration lookup per idle tick');
    is($validations,10,'runtime validation remains active across ticks');
    my $response=GeoPresence_Get($c,'GP','timerStats','format=json');
    my $stats=eval {JSON::PP::decode_json($response)};
    ok(ref($stats) eq 'HASH','read-only timer statistics available');
    if (ref($stats) eq 'HASH') {
        is($stats->{last_device_scans},0,'no full device catalogue scan in an idle tick');
        is($stats->{last_config_builds},0,'statistics show no idle configuration build');
        cmp_ok($stats->{runs},'>=',11,'statistics count measured callbacks');
    }
    ok(!defined($c->{helper}{gp_work}),'profiling context is not retained between timer runs');
    my ($readings_before,$commands_before,$messages_before)=($reading_calls,scalar @commands,scalar @messages);
    GeoPresence_Get($c,'GP','timerStats','format=json');
    is_deeply([$reading_calls,scalar @commands,scalar @messages],[$readings_before,$commands_before,$messages_before],
        'statistics getter produces no readings, commands or messages');
    $defs{GP}{READINGS}{mode}{VAL}='active';
    $attr{rr_Test}{rr_geofenceUUIDs}='external-change';
    config_event('ATTR rr_Test rr_geofenceUUIDs external-change');
    advance(1);GeoPresence_Timer($c);
    like(join(' ',@{$c->{helper}{gp}{errors}{'Geo.Test'}}),qr/remove rr_geofenceUUIDs/,
        'next tick notices a changed external ROOMMATE guard without a GeoPresence attribute callback');
    delete $attr{rr_Test}{rr_geofenceUUIDs};
    config_event('DELETEATTR rr_Test rr_geofenceUUIDs');
    advance(1);GeoPresence_Timer($c);
    is_deeply($c->{helper}{gp}{errors}{'Geo.Test'},[],'next tick revalidates repaired external configuration');
};

subtest 'timer rearms after completion and retains only a new session timer after callbacks reset it' => sub {
    my ($c)=fixture();$defs{GP}{READINGS}{mode}{VAL}='debug';
    my $dir=tempdir(CLEANUP=>1);
    attribute('GP','logFile',"$dir/timer.log");
    my $validate=\&GP_Validate;
    {
        no warnings 'redefine';
        local *GP_Validate=sub {advance(2.5);return $validate->(@_)};
        GeoPresence_Timer($c);
    }
    my @scheduled=grep {$_->[1] eq 'GeoPresence_Timer' && $_->[2]==$c} @timers;
    is(scalar @scheduled,1,'slow callback leaves one timer');
    cmp_ok($scheduled[0][0],'>',$now,'slow callback schedules in the future, not before its completion');
    ok(scalar(grep {/GeoPresence timer_slow/} diagnostic_lines($c)),'slow callback produces a bounded diagnostic');
    {
        no warnings 'redefine';
        local *GP_Validate=sub {advance(2.5);return $validate->(@_)};
        for (1..3) {advance(1);GeoPresence_Timer($c);}
        is(scalar(grep {/GeoPresence timer_slow/} diagnostic_lines($c)),1,'repeated slow work emits at most one warning per minute');
        advance(61);GeoPresence_Timer($c);
        is(scalar(grep {/GeoPresence timer_slow/} diagnostic_lines($c)),2,'continued slow work is reported again after a minute');
    }
    my $stats=JSON::PP::decode_json(GeoPresence_Get($c,'GP','timerStats','format=json'));
    is($stats->{slow_runs},5,'all slow runs are counted even when their log messages are limited');
    is($stats->{last_ms},2500,'durations use milliseconds on the monotonic clock');
    GP_ResetController($c);
    is(JSON::PP::decode_json(GeoPresence_Get($c,'GP','timerStats','format=json'))->{runs},$stats->{runs},
        'session reset does not erase timer diagnosis');
    ($c)=fixture();
    my $epoch=$c->{helper}{gp}{epoch};
    {
        no warnings 'redefine';
        local *GP_Publish=sub {GP_ResetController($c)};
        GeoPresence_Timer($c);
    }
    cmp_ok($c->{helper}{gp}{epoch},'>',$epoch,'callback simulated a session reset');
    @scheduled=grep {$_->[1] eq 'GeoPresence_Timer' && $_->[2]==$c} @timers;
    is(scalar @scheduled,1,'superseded callback does not add a second timer to the new session');
    is($scheduled[0][0],$now+0.1,'new session initialization keeps its intended timer');
};

subtest 'idle logging does not revisit a full already emitted trace' => sub {
    my ($c)=fixture();my $s=GP_State($c,'Geo.Test',0);
    for (1..1000) {GP_Trace($s,$now,'idle trace entry',{diagnostic_only=>1});}
    GP_LogTrace($c,'Geo.Test',$s,0);
    {
        package GeoPresenceTraceProbe;
        sub TIEARRAY {bless {rows=>$_[1],fetches=>0},$_[0]}
        sub FETCHSIZE {scalar @{$_[0]{rows}}}
        sub FETCH {$_[0]{fetches}++;$_[0]{rows}[$_[1]]}
    }
    tie my @trace,'GeoPresenceTraceProbe',$s->{trace};
    my $probe=tied @trace;
    {
        local $s->{trace}=\@trace;
        GP_LogTrace($c,'Geo.Test',$s,0);
    }
    cmp_ok($probe->{fetches},'<',10,'already logged history requires constant work at idle');
    GP_Trace($s,$now,'new tail row',{diagnostic_only=>1}) for 1..3;
    $probe->{fetches}=0;
    {
        local $s->{trace}=\@trace;
        GP_LogTrace($c,'Geo.Test',$s,0);
    }
    cmp_ok($probe->{fetches},'<',15,'only the new tail is read after old rows are pruned');
    is($s->{log_sequence},$s->{trace_sequence},'new decisions are still marked as logged');
};

subtest 'idle validation skips fingerprint serialization and event snapshots retain revisions' => sub {
    my ($c)=fixture();$defs{GP}{READINGS}{mode}{VAL}='debug';
    my $cfg=GP_Config($c,'Geo.Test',1);
    ok(!exists($cfg->{revision}),'building a snapshot does not serialize it');
    my $fingerprints=0;my $original=\&GP_ConfigRevision;
    {
        no warnings 'redefine';
        local *GP_ConfigRevision=sub {$fingerprints++;return $original->(@_)};
        for (1..10) {advance(1);GeoPresence_Timer($c);}
    }
    is($fingerprints,0,'idle timer computes no fingerprints');
    my $revision=GP_ConfigRevision($cfg);
    like($revision,qr/\A[0-9a-f]{64}\z/,'event snapshot can produce a full fingerprint');
    is(GP_ConfigRevision($cfg),$revision,'same immutable snapshot has stable revision');
    $attr{'Geo.Test'}{allowDoor}=0;
    config_event('ATTR Geo.Test allowDoor 0');
    my $changed=GP_Config($c,'Geo.Test',1);
    isnt(GP_ConfigRevision($changed),$revision,'new snapshot reflects a changed permission');
    advance(40);my $s=new_state();advance(40);
    GP_Process($s,$changed,ev('Home',1,$now),$now,$mono);
    is($s->{config_revision},$changed->{revision},'decision trace receives evaluated configuration revision');
    my $residents=\&GP_Residents;my $scans=0;
    {
        no warnings 'redefine';
        local *GP_Residents=sub {$scans++;return $residents->(@_)};
        local $defs{rr_Test}{CHANGED}=['durTimerPresence: 01:00:00'];
        GeoPresence_Notify($c,$defs{rr_Test});
    }
    is($scans,0,'ROOMMATE duration events do not scan residents');
};

subtest 'timer lateness is separate from work and uses a monotonic deadline' => sub {
    my ($c)=fixture();$defs{GP}{READINGS}{mode}{VAL}='debug';
    GeoPresence_Timer($c);advance(3.5);GeoPresence_Timer($c);
    my $stats=JSON::PP::decode_json(GeoPresence_Get($c,'GP','timerStats','format=json'));
    is($stats->{last_lag_ms},2500,'time after planned start is measured');
    is($stats->{max_lag_ms},2500,'longest start delay retained');
    is($stats->{late_runs},1,'late callback counted');
    is($stats->{slow_runs},0,'waiting before invocation is not work');
    is($stats->{last_ms},0,'controlled clock reports only time in callback');
    is($stats->{last_started_at},$now,'start timestamp available for correlation');
    $now+=3600;$mono+=1;GeoPresence_Timer($c);
    $stats=JSON::PP::decode_json(GeoPresence_Get($c,'GP','timerStats','format=json'));
    is($stats->{last_lag_ms},0,'wall clock jump does not fake a delayed scheduler');
    is($stats->{late_runs},1,'wall clock change adds no late run');
};

subtest 'switch_on is bounded, deduplicated, validated and suppressed in debug' => sub {
    my ($c)=fixture();$defs{GP}{READINGS}{mode}{VAL}='debug';
    device('test.dev.licht','dummy');
    gp_define('A.Light','action GP switch_on');$attr{'A.Light'}={target=>'test.dev.licht',command=>'on'};
    gp_define('R.Light','rule GP');$attr{'R.Light'}={trigger=>'enter',residents=>'Geo.Test',locations=>'Z.Sternensteg',action=>'A.Light',cooldown=>10};
    is_deeply([GP_Validate($c)],[],'new switch action and zone rule validate');
    my $cfg=GP_Config($c,'Geo.Test',1);my $s=GP_State($c,'Geo.Test',1);advance(40);
    process($s,$cfg,'Sternensteg',1);
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['switch_on'],'zone entry schedules switch without door permission');
    my $before=$reading_calls;
    GP_Dispatch($c,'Geo.Test',$cfg,$s,1,$now,$mono);
    is(scalar @commands,0,'debug emits no switch command');
    is(scalar @messages,0,'debug sends no messages');
    is($reading_calls,$before,'debug produces no readings');
    like($s->{last_reason},qr/debug suppressed/,'switch plan is visible in trace');
    advance(12);process($s,$cfg,'Sternensteg',1);
    is(scalar @{$s->{intents}},0,'duplicate entry cannot retrigger after cooldown without a new visit');
    advance(1);process($s,$cfg,'Sternensteg',0);advance(1);process($s,$cfg,'Sternensteg',1);
    is(scalar @{$s->{intents}},1,'new visit after cooldown schedules again');
    mode('GP','active');$cfg=GP_Config($c,'Geo.Test',0);$s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Sternensteg',1);
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is_deeply(\@commands,['test.dev.licht on'],'active adapter sends exactly the fixed on command');
    is_deeply($c->{helper}{gp}{actors},{},'switch creates no opening reservation');
    advance(1);process($s,$cfg,'Sternensteg',0);advance(1);process($s,$cfg,'Sternensteg',1);
    is(scalar @{$s->{intents}},0,'another visit inside cooldown is suppressed');
    $defs{GP}{READINGS}{mode}{VAL}='debug';
    for my $bad ('on; set door lock unlocked','off','{ exit }') {
        local $attr{'A.Light'}{command}=$bad;
        config_event("ATTR A.Light command $bad");
        like(join(' ',GP_Validate($c)),qr/command must be on/,'unbounded command rejected');
    }
    {
        local $attr{'A.Light'}{target}='garage';
        config_event('ATTR A.Light target garage');
        like(join(' ',GP_Validate($c)),qr/Conflicting action definitions/,'light cannot share an opening target');
    }
    {
        local $attr{'R.Light'}{trigger}='arrival';
        config_event('ATTR R.Light trigger arrival');
        like(join(' ',GP_Validate($c)),qr/locations is not applicable/,'arrival rules reject an irrelevant location selector');
    }
    {
        local $attr{'A.Light'}{target}='missing';
        config_event('ATTR A.Light target missing');
        like(join(' ',GP_Validate($c)),qr/missing target device/,'undefined target rejected');
    }
};

subtest 'three resident policies retain door, garage and phone arrival contracts' => sub {
    my ($c)=fixture(); $defs{GP}{READINGS}{mode}{VAL}='debug';
    # Current policy fixture, independent of retired installation instructions.
    for my $suffix (qw(Lumo Neris Piko)) {
        my $r='Geo.'.$suffix;
        device('rr_'.$suffix,'ROOMMATE');
        $attr{'rr_'.$suffix}{rr_locationUnderway}='underway';
        gp_define($r,'resident GP rr_'.$suffix);
        $attr{$r}={phoneProxies=>'p1,p2,p3,p4,p5',
            phoneSignalMode=>'state',allowDoor=>1,allowGarage=>$suffix eq 'Piko'?0:1}; GP_StoreMode($defs{$r},'active');
        for my $role (qw(home outer)) {
            my $z=$r.'.'.$role;
            gp_define($z,"location $r $role");
            $attr{$z}{zoneId}=lc($suffix).'-'.$role;
        }
    }
    $attr{'R.Door'}{residents}='Geo.Lumo,Geo.Neris,Geo.Piko';
    $attr{'R.Late'}{residents}='Geo.Lumo,Geo.Neris';
    for my $r (qw(Geo.Lumo Geo.Neris Geo.Piko)) {
        my $cfg=GP_Config($c,$r);
        is($cfg->{sourceMode},'geofency_phone',"$r uses the same Geo/phone arrival contract");
        is($cfg->{allowDoor},1,"$r may open the front door");
        is($cfg->{allowGarage},$r eq 'Geo.Piko' ? 0:1,"$r has the intended garage permission");
        is(scalar(@{$cfg->{roles}{home}//[]}),1,"$r has a Home location");
        is(scalar(@{$cfg->{roles}{outer}//[]}),1,"$r has an outer location");
        if ($r eq 'Geo.Piko') {
            is(scalar(@{$cfg->{roles}{work}//[]}),0,'Piko does not need a workplace');
            is_deeply([map {$_->{type}} @{$cfg->{rules}}],['door_open'],'Piko has the door rule without garage or work notifications');
        }
        next unless @{$cfg->{roles}{home}//[]}==1 && @{$cfg->{roles}{outer}//[]}==1;
        my $home=$cfg->{roles}{home}[0];my $outer=$cfg->{roles}{outer}[0];
        # Synthetic metadata represents completed learning, never production data.
        for my $z (values %{$cfg->{zones}}) {
            @{$z}{qw(lat lon radius)}=(0,0,$z->{role} eq 'outer' ? 4500:50);
        }
        $cfg->{geometry_errors}=[GP_GeometryErrors($cfg)];
        $cfg->{geometry_ready}=!@{$cfg->{geometry_errors}};
        ok($cfg->{geometry_ready},"$r can be ready without DriveIn or an extra workplace");
        for my $scope (qw(remote local jitter)) {
            for my $source (qw(geo phone)) {
                my $s=new_state();advance(40);
                my $event=sub {return {kind=>'geo',zone=>$_[0],entry=>$_[1],time=>$now,received=>$now,motion=>$_[2]//'unknown'};};
                my $depart=$scope eq 'remote' ? $outer:$home;
                GP_Process($s,$cfg,$event->($depart,0),$now,$mono);
                if ($scope eq 'local') {
                    advance(1);
                    my $samples={map {$_=>{value=>'absent',time=>$now,ttl=>150,healthy=>1}} @{$cfg->{proxies}}};
                    phone_tick($s,$cfg,$samples);advance(180);phone_tick($s,$cfg,$samples);
                    ok($s->{trip}{armed},"$r local walk qualifies with held negatives");
                } else { advance(90); }
                if ($source eq 'geo') {
                    GP_Process($s,$cfg,$event->($home,1,$scope eq 'remote' ? 'automotive':'unknown'),$now,$mono);
                    complete_arrival($s,$cfg);
                } else {
                    my $samples={map {$_=>{value=>'absent',time=>$now,ttl=>150,healthy=>1}} @{$cfg->{proxies}}};
                    $samples->{$cfg->{proxies}[3]}{value}='present';
                    phone_tick($s,$cfg,$samples);
                }
                my @expected=$scope eq 'jitter' ? () : ('door_open');
                push @expected,'garage_open' if $scope eq 'remote' && $r ne 'Geo.Piko';
                is_deeply([map {$_->{kind}} @{$s->{intents}}],\@expected,"$r $scope return via $source has exactly the intended actions");
                is($s->{desired_status},'home',"$r return synchronizes home");
                GP_Dispatch($c,$r,$cfg,$s,1,$now,$mono);
                advance(5);
                GP_Process($s,$cfg,$event->($home,1),$now,$mono);
                is(scalar @{$s->{intents}},0,"$r duplicate arrival does not open again");
            }
        }
        if ($r eq 'Geo.Piko') {
            # Even if a shared garage rule is later extended to Piko by mistake,
            # her explicit permission must still veto remote/automotive arrivals.
            my ($garage)=grep {$_->{type} eq 'garage_open'} @{GP_Config($c,'Geo.Lumo')->{rules}};
            push @{$cfg->{rules}},$garage;
            push @{$cfg->{rule_index}{arrival}{arrival}},$garage;
            my $s=new_state();advance(40);
            GP_Process($s,$cfg,{kind=>'geo',zone=>$outer,entry=>0,time=>$now,received=>$now},$now,$mono);
            advance(90);
            GP_Process($s,$cfg,{kind=>'geo',zone=>$home,entry=>1,time=>$now,received=>$now,motion=>'automotive'},$now,$mono);
            complete_arrival($s,$cfg);
            is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'Piko garage permission also overrides an accidentally shared garage rule');
        }
    }
    is(scalar @commands,0,'debug evaluation of all resident arrivals executes no commands');
    is(scalar @messages,0,'debug evaluation of all resident arrivals sends no notifications');
};


sub pending_fixture {
    my ($motion,%options)=@_;
    my ($c,$cfg)=fixture(%options);my $s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Work',0);advance(90);actor_fresh();
    process($s,$cfg,'Home',1,$motion);
    return ($c,$cfg,$s);
}

subtest 'motion selects a real pending wait without consuming the trip' => sub {
    for my $case ([walking=>60],[running=>30],[cycling=>20],[automotive=>10],[unknown=>60],[stationary=>60]) {
        my ($motion,$wait)=@$case;
        my ($c,$cfg,$s)=pending_fixture($motion);
        is($s->{phase},'returning',"$motion is provisional");
        is($s->{arrival}{wait},$wait,"$motion wait");
        my $trip=$s->{trip}{id};ok($s->{trip}{armed},'departure permission remains');
        is(scalar @{$s->{intents}},0,'no immediate action');
        GP_Publish($c,'Geo.Test',$cfg,$s);
        is(GP_Read('Geo.Test','gp_arrival_pending',0),1,'pending reading visible');
        advance($wait-0.1);GP_ConfirmArrival($s,$cfg,$now,$mono);
        is(scalar @{$s->{intents}},0,'nothing before deadline');
        advance(0.1);GP_ConfirmArrival($s,$cfg,$now,$mono);
        is($s->{phase},'home','deadline confirms home');
        is($s->{last_trip}{id},$trip,'same trip completed');
        is(scalar(grep {$_->{kind} eq 'door_open'} @{$s->{intents}}),1,'one door plan');
        is(scalar(grep {$_->{kind} eq 'garage_open'} @{$s->{intents}}),$motion =~ /walking|running|cycling/ ? 0:1,'garage policy unchanged');
        GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);GP_Publish($c,'Geo.Test',$cfg,$s);
        ok(!exists $s->{arrival},'publication does not recreate an empty pending arrival');
    }
};

subtest 'display expiry preserves a waiting Home arrival and its original evidence' => sub {
    for my $profile (qw(geofency_only geofency_phone)) {
      for my $motion (qw(unknown walking)) {
       for my $label ('home','Home','Zuhause') {
        my ($c,$cfg,$s)=pending_fixture($motion,source_mode=>$profile,zone_display_max_age=>20,home_label=>$label);
        my $due=$s->{arrival}{due_mono};my $observed=$s->{zones}{'Z.Home'}{time};
        my $evidence=JSON::PP->new->canonical->encode([@$s{qw(zones members arrival trip)}]);
        advance(20);GP_TickState($s,$cfg,$now,$mono);
        is($s->{location},$label,"$profile, $motion, $label: display remains at its age limit");
        advance(1);GP_TickState($s,$cfg,$now,$mono);
        is($s->{location},'unknown','old location is hidden');
        GP_Publish($c,'Geo.Test',$cfg,$s);
        is(GP_Read('Geo.Test','gp_location',''),'unknown','the expired display is published');
        is(JSON::PP->new->canonical->encode([@$s{qw(zones members arrival trip)}]),$evidence,
            'display expiry changes no accepted location, membership, arrival or trip evidence');
        is(scalar @{$s->{intents}},0,'display expiry creates no output');
        advance($due-$mono-1);GP_TickState($s,$cfg,$now,$mono);GP_ConfirmArrival($s,$cfg,$now,$mono);
        is(scalar @{$s->{intents}},0,'the original wait still applies');
        advance(1);GP_TickState($s,$cfg,$now,$mono);GP_ConfirmArrival($s,$cfg,$now,$mono);
        is($s->{phase},'home','the valid arrival completes at its original deadline');
        ok(!$s->{arrival},'confirmation consumes the pending arrival');
        is($s->{zones}{'Z.Home'}{time},$observed,'confirmation does not refresh the original observation');
        actor_fresh();GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        GP_Publish($c,'Geo.Test',$cfg,$s);
        is($s->{location},'unknown','confirmation cannot revive an expired Geo display');
        is(GP_Read('Geo.Test','gp_location',''),'unknown','confirmation publishes no temporary Home label');
        my @expected=$motion eq 'walking' ? ('door lock unlocked'):('door lock unlocked','garage on');
        is_deeply([grep {/^(?:door|garage) /} @commands],\@expected,'only the original eligible openings are issued');
        advance(1);GP_TickState($s,$cfg,$now,$mono);GP_ConfirmArrival($s,$cfg,$now,$mono);
        GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        GP_Publish($c,'Geo.Test',$cfg,$s);
        is(GP_Read('Geo.Test','gp_location',''),'unknown','the next tick preserves the same expired display');
        is_deeply([grep {/^(?:door|garage) /} @commands],\@expected,'a later tick cannot repeat the arrival');
       }
      }
    }
};

subtest 'fresh observations retain their display when Home is confirmed' => sub {
    for my $source (qw(home overlap phone_return phone_veto)) {
        my ($c,$cfg,$s)=pending_fixture('walking',zone_display_max_age=>20,home_label=>'Zuhause');
        my $due=$s->{arrival}{due_mono};my $original=$s->{arrival}{event}{time};
        advance(21);GP_TickState($s,$cfg,$now,$mono);
        is($s->{location},'unknown',"$source: initial Geo display expired");
        advance(34);
        if ($source eq 'home') {process($s,$cfg,'Home',1,'unknown');}
        elsif ($source eq 'overlap') {
            @{$cfg->{zones}{'Z.Checkpoint'}}{qw(lat radius)}=(0.0002,20);
            process($s,$cfg,'Checkpoint',1);
            ok($s->{zones}{'Z.Home'}{entry},'the overlapping place does not disprove Home');
        } else {
            GP_Process($s,$cfg,{kind=>'phone_present',time=>$now,received=>$now,generation=>$s->{generation},
                arrival=>$source eq 'phone_return' ? 1:0,key=>'fresh-phone-display'},$now,$mono);
        }
        my $expected=$source eq 'home' ? 'Zuhause':$source eq 'overlap' ? 'Checkpoint':'home';
        is($s->{location},$expected,'the actual new observation updates the display');
        if ($source eq 'home' || $source eq 'overlap') {
            is($s->{arrival}{due_mono},$due,'the original wait remains unchanged');
            is($s->{arrival}{event}{time},$original,'the original arrival observation remains unchanged');
        }
        advance($due-$mono);GP_TickState($s,$cfg,$now,$mono);GP_ConfirmArrival($s,$cfg,$now,$mono);
        is($s->{phase},'home','the valid presence reaches Home status');
        is($s->{location},$expected,'Home status preserves the latest actual display');
        actor_fresh();GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);GP_Publish($c,'Geo.Test',$cfg,$s);
        is(GP_Read('Geo.Test','gp_location',''),$expected,'the latest display is published');
        my @expected_commands=$source eq 'phone_veto' ? ():('door lock unlocked');
        is_deeply([grep {/^(?:door|garage) /} @commands],\@expected_commands,'source and walking restrictions retain their effect');
    }
};

subtest 'real location changes still revoke Home after its display expires' => sub {
    for my $counterproof (qw(home_exit surrounding_exit disjoint_position)) {
        my ($c,$cfg,$s)=pending_fixture('unknown',source_mode=>'geofency_only',zone_display_max_age=>20);
        my $due=$s->{arrival}{due_mono};my $trip=$s->{trip}{id};
        advance(21);GP_TickState($s,$cfg,$now,$mono);
        ok($s->{zones}{'Z.Home'}{entry},"$counterproof: expiry alone preserves Home");
        advance(1);
        if ($counterproof eq 'home_exit') {process($s,$cfg,'Home',0);}
        elsif ($counterproof eq 'surrounding_exit') {process($s,$cfg,'Drive',0);}
        else {
            @{$cfg->{zones}{'Z.Checkpoint'}}{qw(lat radius)}=(0.001,20);
            process($s,$cfg,'Checkpoint',1);
            is($s->{trip}{id},$trip,'a nearby disjoint place does not replace the trip');
            ok($s->{arrival},'the candidate remains until the final evidence check');
            ok(!$s->{zones}{'Z.Home'}{entry},'the newer position disproves Home');
        }
        advance($due-$mono);GP_TickState($s,$cfg,$now,$mono);GP_ConfirmArrival($s,$cfg,$now,$mono);
        ok(!$s->{arrival},'the actual counterproof cancels the arrival');
        actor_fresh();GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        is(scalar(grep {/^(?:door|garage) /} @commands),0,'no physical opening follows');
    }
};

subtest '15 second false Home visit during an armed walk cancels and later arrival still works' => sub {
    my ($c,$cfg,$s)=pending_fixture('walking');my $trip=$s->{trip}{id};
    advance(15);process($s,$cfg,'Home',0);
    ok(!$s->{arrival},'exit cancels the candidate');is($s->{trip}{id},$trip,'original outing retained');
    advance(60);GP_TickState($s,$cfg,$now,$mono);GP_ConfirmArrival($s,$cfg,$now,$mono);
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is(scalar @commands,0,'false arrival never opened anything');
    process($s,$cfg,'Home',1,'walking');my $deadline=$s->{arrival}{due_mono};
    advance(59);GP_ConfirmArrival($s,$cfg,$now,$mono);is(scalar @{$s->{intents}},0,'prior visit cannot contribute waiting time');
    advance(1);GP_ConfirmArrival($s,$cfg,$now,$mono);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is_deeply(\@commands,['door lock unlocked'],'real return opens only the door');
};

subtest 'new phone arrival confirms early, continuous room presence does not' => sub {
    for my $arrival (0,1) {
        my ($c,$cfg,$s)=pending_fixture('walking');advance(5);
        GP_Process($s,$cfg,{kind=>'phone_present',time=>$now,received=>$now,generation=>$s->{generation},arrival=>$arrival,key=>'new-phone'},$now,$mono);
        is($s->{phase},'home','local phone establishes home');ok(!$s->{arrival},'pending wait cleared');
        is(scalar @{$s->{intents}},$arrival ? 1:0,'only an actual return supplies the early opening');
        GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        advance(60);GP_ConfirmArrival($s,$cfg,$now,$mono);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        is(scalar @commands,$arrival ? 1:0,'timer cannot repeat the phone result');
    }
};

subtest 'phone detected 200 seconds after walking entry cannot issue another door pulse' => sub {
    my ($c,$cfg,$s)=pending_fixture('walking');advance(60);GP_ConfirmArrival($s,$cfg,$now,$mono);
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    actor_event($c,'feedback','pulse_state','confirmed');GP_ActorFeedback($c,$now,$mono);
    advance(140);GP_Process($s,$cfg,{kind=>'phone_present',time=>$now,received=>$now,generation=>$s->{generation},arrival=>1,key=>'later-phone'},$now,$mono);
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is_deeply(\@commands,['door lock unlocked'],'one trip, one opening even after completed feedback');
};

subtest 'retries and new unknown Home reports do not move the deadline' => sub {
    my ($c,$cfg,$s)=pending_fixture('walking');my $e={%{$s->{arrival}{event}}};my $due=$s->{arrival}{due_mono};
    advance(10);GP_Process($s,$cfg,$e,$now,$mono);
    is($s->{arrival}{due_mono},$due,'identical retry does not restart');
    advance(10);process($s,$cfg,'Home',1,'unknown');
    is($s->{arrival}{due_mono},$due,'new inconclusive report does not restart');
    is($s->{arrival}{motion},'walking','walking remains selected');
    advance(40);GP_ConfirmArrival($s,$cfg,$now,$mono);
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'original wait completes once');
};

subtest 'new useful motion changes the deadline relative to the first Home receipt' => sub {
    my ($c,$cfg,$s)=pending_fixture('unknown');my $start=$s->{arrival}{start_mono};
    advance(5);process($s,$cfg,'Home',1,'automotive');
    is($s->{arrival}{due_mono},$start+10,'new car evidence shortens, without restarting');
    advance(2);process($s,$cfg,'Home',1,'walking');
    is($s->{arrival}{due_mono},$start+60,'latest walking restores foot wait despite older automotive');
};

subtest 'fast waits need motion at most 30 seconds old in the current arrival section' => sub {
    for my $age (10,31) {
        my ($c,$cfg)=fixture();$cfg->{rules}=[grep {$_->{trigger} ne 'approach'} @{$cfg->{rules}}];
        my $s=new_state();advance(40);process($s,$cfg,'Work',0);advance(90);
        process($s,$cfg,'Drive',1,'automotive');advance($age);process($s,$cfg,'Home',1);
        is($s->{arrival}{wait},$age==10 ? 10:60,'age controls only fast arrival confirmation');
        ok($s->{arrival}{vehicle_eligible},'garage keeps its separate motion validity');
    }
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Work',0,'automotive');
    advance(90);process($s,$cfg,'Home',1);
    is($s->{arrival}{wait},60,'motion from Work cannot shorten a Home wait');
};

subtest 'delayed delivery does not shorten waiting or turn an old car observation fresh' => sub {
    my ($c)=fixture();my $cfg=GP_Config($c,'Geo.Test',1);my $s=GP_State($c,'Geo.Test',1);
    advance(40);process($s,$cfg,'Work',0);advance(140);
    my $e=ev('Home',1,$now-40,'automotive');$e->{received}=$now;
    GP_Process($s,$cfg,$e,$now,$mono);
    is($s->{arrival}{wait},60,'old car report uses unknown wait');is($s->{arrival}{due_mono},$mono+60,'wait begins at receipt');
    advance(60);GP_ConfirmArrival($s,$cfg,$now,$mono);
    is(scalar @{$s->{intents}},2,'deliberate wait is allowed without rewriting original timestamps');
    is($s->{intents}[0]{e}{time},$e->{time},'original phone date retained');
    GP_Dispatch($c,'Geo.Test',$cfg,$s,1,$now,$mono);
    like($s->{last_reason},qr/debug suppressed/,'intent survives intentional wait beyond action_max_age');
};

subtest 'waiting never expires a foot veto into a remote garage permission' => sub {
    my ($c,$cfg)=fixture();$cfg->{rules}=[grep {$_->{trigger} ne 'approach'} @{$cfg->{rules}}];
    my $s=new_state();advance(40);process($s,$cfg,'Work',0);advance(90);
    process($s,$cfg,'Drive',1,'walking');advance(170);process($s,$cfg,'Home',1);
    is($s->{arrival}{motion},'walking','still-fresh foot evidence selected at Home');
    advance(60);GP_ConfirmArrival($s,$cfg,$now,$mono);
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'expiry during wait cannot enable garage');
};

subtest 'timer cannot confirm while a newer exit is still queued for reordering' => sub {
    for my $exit (qw(Home Drive Outer Work)) {
        my ($c,$cfg)=fixture();advance(40);actor_fresh();http($c,form($cfg,'Work',0,$now));advance(3);GeoPresence_Timer($c);
        advance(90);http($c,form($cfg,'Home',1,$now,motion=>'walking'));advance(3);GeoPresence_Timer($c);
        my $s=$c->{helper}{gp}{prod}{'Geo.Test'};my $due=$s->{arrival}{due_mono};
        advance($due-$mono-1);http($c,form($cfg,$exit,$exit eq 'Work'?1:0,$now));
        advance(1);GeoPresence_Timer($c);
        is(scalar(grep {/^(door|garage) /} @commands),0,"$exit still queued at deadline: no commands");
        advance(2);GeoPresence_Timer($c);
        ok(!$s->{arrival},"$exit cancels after ordered processing");
        is(scalar(grep {/^(door|garage) /} @commands),0,"$exit prevented opening");
    }
};

subtest 'configuration reset, manual home, clock jump, and conflicting observations revoke pending arrival' => sub {
    for my $cancel (qw(reset manual clock conflict)) {
        my ($c,$cfg,$s)=pending_fixture('automotive');
        if ($cancel eq 'reset') {GP_ResetController($c);$s=GP_State($c,'Geo.Test',0);}
        elsif ($cancel eq 'manual') {local $defs{rr_Test}{CHANGED}=['home'];GeoPresence_Notify($c,$defs{rr_Test});}
        elsif ($cancel eq 'clock') {$now+=100;GeoPresence_Timer($c);}
        else {process($s,$cfg,'Home',0);}
        ok(!$s->{arrival},"$cancel removed pending state");
        advance(60);GP_ConfirmArrival($s,$cfg,$now,$mono);GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        is(scalar @commands,0,"$cancel does not revive timer permission");
    }
};

subtest 'a delayed exit between two processed Home entries restarts the wait at the later receipt' => sub {
    my ($c,$cfg,$s)=pending_fixture('walking');my $trip=$s->{trip}{id};my $first=$now;
    advance(30);process($s,$cfg,'Home',1,'walking');my $second_due=$mono+60;
    advance(10);my $exit=ev('Home',0,$first+15);$exit->{received}=$now;
    GP_Process($s,$cfg,$exit,$now,$mono);
    is($s->{arrival}{due_mono},$second_due,'late exit disqualifies the first interval');
    is($s->{trip}{id},$trip,'late exit does not create a new trip');
    is($s->{position_time},$first+30,'newer position is not rewound');
    advance(20);GP_ConfirmArrival($s,$cfg,$now,$mono);
    is(scalar @{$s->{intents}},0,'original deadline cannot open');
    advance(30);GP_ConfirmArrival($s,$cfg,$now,$mono);
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'later uninterrupted wait confirms');

    ($c,$cfg)=fixture();advance(40);actor_fresh();http($c,form($cfg,'Work',0,$now));advance(3);GeoPresence_Timer($c);
    advance(90);$first=$now;http($c,form($cfg,'Home',1,$now,motion=>'walking'));advance(3);GeoPresence_Timer($c);
    advance(27);my $second=$now;http($c,form($cfg,'Home',1,$now,motion=>'walking'));advance(3);GeoPresence_Timer($c);
    advance(7);http($c,form($cfg,'Home',0,$first+15));advance(3);GeoPresence_Timer($c);
    $s=$c->{helper}{gp}{prod}{'Geo.Test'};
    is($s->{arrival}{started},$second,'real HTTP/geometry preprocessing still allows the delayed exit to interrupt');
    advance(17);GeoPresence_Timer($c);
    is(scalar(grep {/^(door|garage) /} @commands),0,'first HTTP deadline cannot open');
    advance(30);GeoPresence_Timer($c);
    is(scalar(grep {$_ eq 'door lock unlocked'} @commands),1,'second HTTP deadline opens once');
};

subtest 'timer stalls cannot open after the intentional wait plus freshness budget' => sub {
    my ($c,$cfg,$s)=pending_fixture('automotive');advance(101);GP_ConfirmArrival($s,$cfg,$now,$mono);
    ok(!$s->{arrival},'stale pending confirmation discarded');is(scalar @{$s->{intents}},0,'no late opening');
    like($s->{trace}[-1]{confirmation},qr/expired/,'explicit expiration diagnostic');
};

subtest 'arrival parameters validate, default correctly and do not disable departure protection' => sub {
    my ($c,$cfg)=fixture();$defs{GP}{READINGS}{mode}{VAL}='debug';
    for my $key (qw(arrival_wait_walking arrival_wait_running arrival_wait_cycling arrival_wait_automotive arrival_wait_unknown arrival_motion_max_age)) {
        for my $bad (0,-1,301,'bad') {ok(GeoPresence_Attr('set','GP',$key,$bad),"reject $key=$bad");}
        is(GeoPresence_Attr('set','GP',$key,12),undef,"accept custom $key");
    }
    my $s=new_state();advance(40);process($s,$cfg,'Home',0);advance(10);process($s,$cfg,'Home',1,'automotive');
    ok(!$s->{arrival},'unqualified exit does not create a timed permission');
    advance(60);GP_ConfirmArrival($s,$cfg,$now,$mono);is(scalar @{$s->{intents}},0,'time and car alone do not authorize opening');
};

subtest 'human reports explain pending arrival and keep the machine-readable contract explicit' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Outer',0);advance(90);process($s,$cfg,'Home',1,'automotive');
    my $before=JSON::PP->new->canonical->encode($s);
    my $text=GeoPresence_Get($c,'GP','explain','Geo.Test');
    like($text,qr/Arrival pending.*10\.0 s/,'human summary describes pending confirmation');
    like($text,qr/Presence\s+: Returning/,'readable presence instead of a raw state dump');
    like($text,qr/Eligible after arrival confirmation; no request sent yet/,'eligibility is not dispatch');
    like(GeoPresence_Get($c,'GP','explain','Geo.Test'),qr/Confirmation due\s+: \d{4}-\d\d-\d\d /,'detailed timestamps are local and readable');
    unlike($text,qr/seen_order|event_key|\{"production"/,'implementation bookkeeping is omitted');
    my $json=JSON::PP::decode_json(GeoPresence_Get($c,'GP','explain','Geo.Test','format=json'));
    is($json->{state}{arrival}{wait},10,'explicit JSON retains the full original state');
    is(JSON::PP->new->canonical->encode($s),$before,'report and JSON do not mutate trip, trace or timers');
    is(scalar @commands,0,'reports issue no commands');
    is(scalar @messages,0,'reports send no messages');
    advance(9);like(GeoPresence_Get($c,'GP','explain','Geo.Test'),qr/confirmation in 1\.0 s/,'remaining time is calculated at the snapshot');
    advance(2);like(GeoPresence_Get($c,'GP','explain','Geo.Test'),qr/confirmation due.*waiting for event processing/,'overdue timer is not executed by get');
    ok($s->{arrival},'due arrival remains pending until normal processing');
};

subtest 'reports distinguish no permission, simulation and previous actuator results' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Home',1);
    my $text=GeoPresence_Get($defs{'Geo.Test'},'Geo.Test','explain');
    like($text,qr/At home.*no new opening planned/,'resident get infers its resident');
    like($text,qr/No qualified active trip/,'status-only Home entry explains missing permission');
    $s->{door_result}='confirmed';
    like(GeoPresence_Get($c,'GP','explain','Geo.Test'),qr/Latest door result\s+: Opening confirmed/,'previous completion remains visible');
    like(GeoPresence_Get($c,'GP','explain','Geo.Test'),qr/No new request planned; latest result: Opening confirmed/,'a completed request is not presented as a failed permission');
    my $debug=GP_State($c,'Geo.Test',1);$debug->{phase}='away';$debug->{phone_mode}='simulated';$debug->{sim_phone}='absent';
    $defs{'Geo.Test'}{READINGS}{mode}{VAL}='debug';
    $text=GeoPresence_Get($c,'GP','explain','Geo.Test','debug');
    like($text,qr/Simulation only.*no device commands, messages or ROOMMATE changes/,'effective debug mode is prominent');
    like($text,qr/Phone\s+: .*\(simulated\)/,'simulated sources are never presented as physical observations');
    unlike($text,qr/PRODUCTION|Opening confirmed/,'other state is not mixed into the selected view');
    $defs{GP}{READINGS}{mode}{VAL}='disabled';
    like(GeoPresence_Get($c,'GP','explain','Geo.Test'),qr/Disabled.*no new actions/,'disabled mode is explicit');
};

subtest 'FHEMWEB reports escape text, bound layout and disable automatic link rewriting' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
    $attr{rr_Test}{alias}='Jörg <img src=x onerror="alert(1)"> & friends';
    advance(40);process($s,$cfg,'Home',0);
    my $before=JSON::PP->new->canonical->encode($s);
    local $c->{CL}={TYPE=>'FHEMWEB'};
    local $main::FW_ME='/fhem';local $main::FW_webArgs{addLinks}=1;
    my $html=GeoPresence_Get($c,'GP','explain','Geo.Test');
    like($html,qr/^<html>.*class="gp-report"/s,'FHEMWEB gets native HTML automatically');
    like($html,qr/<details.*Phone sensors/s,'technical sections collapse');
    like($html,qr/overflow-wrap:anywhere/,'long IDs and names can wrap');
    like($html,qr/J&#xF6;rg &lt;img/,'names are escaped after decoding');
    unlike($html,qr/<img|<script/,'data never becomes active markup');
    ok(!$main::FW_webArgs{addLinks},'FHEMWEB cannot rewrite generated HTML');
    like($html,qr/href="\/fhem\?detail=p1"/,'device links are navigation only');
    my $text=GeoPresence_Get($c,'GP','explain','Geo.Test','format=text');
    like($text,qr/<pre.*white-space:pre-wrap/s,'explicit browser text remains safe and wrapping');
    $s->{last_reason}='<script>alert(1)</script> Jörg 🌙';
    my $raw=GeoPresence_Get($c,'GP','explain','Geo.Test','format=json');
    unlike($raw,qr/<script/,'JSON inserted into a FHEMWEB pre cannot inject markup');
    is(JSON::PP::decode_json($raw)->{state}{last_reason},'<script>alert(1)</script> Jörg 🌙','JSON escaping preserves decoded data');
    unlike($raw,qr/[^\x00-\x7f]/,'browser JSON needs no additional FHEMWEB Unicode encoding');
    $s->{last_reason}=JSON::PP::decode_json($before)->{last_reason};
    is(JSON::PP->new->canonical->encode($s),$before,'HTML formatting does not alter production state');
};

subtest 'get format validation, bounded trace and copyable location commands' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',1);
    GP_Trace($s,$now+$_,"Decision $_") for 1..100;
    my $text=GeoPresence_Get($c,'GP','debugTrace','Geo.Test');
    like($text,qr/Showing up to 20 newest entries of 100/,'default history is bounded');
    unlike($text,qr/Decision 80\b/,'older decisions remain hidden by default');
    like(GeoPresence_Get($c,'GP','debugTrace','Geo.Test','limit=2'),qr/Showing up to 2 newest entries of 100/,'human limit retains the total history count');
    my $rows=JSON::PP::decode_json(GeoPresence_Get($c,'GP','debugTrace','Geo.Test','format=json'));
    is(scalar @$rows,100,'JSON keeps full history by default');
    $rows=JSON::PP::decode_json(GeoPresence_Get($c,'GP','debugTrace','Geo.Test','limit=2','format=json'));
    is_deeply([map {$_->{reason}} @$rows],['Decision 99','Decision 100'],'explicit limit keeps newest records without reversing JSON order');
    for my $args (['limit=0'],['limit=1001'],['format=yaml'],['format=text','format=json'],['a','b']) {
        my $answer=GeoPresence_Get($c,'GP','debugTrace','Geo.Test',@$args);
        like($answer,qr/(?:Choose format|limit requires|Too many arguments)/,'malformed output options are rejected');
    }
    my $error=JSON::PP::decode_json(GeoPresence_Get($c,'GP','explain','Missing','format=json'));
    like($error->{error},qr/Specify a resident/,'JSON errors have a stable error field');
    like(GeoPresence_Get($c,'GP','timerStats'),qr/Last\s+: 0 ms/,'timer units are explicit');
    like(GeoPresence_Get($c,'GP','logStatus'),qr/Production diagnostics\s+:/,'log status is readable');
    like(GeoPresence_Get($c,'GP','validate'),qr/^OK: configuration valid/,'Telnet validation retains OK prefix');
    my $validation=JSON::PP::decode_json(GeoPresence_Get($c,'GP','validate','format=json'));
    ok($validation->{valid},'validation also has structured output');
};

subtest 'explain defaults to full production state independently of operating mode' => sub {
    my ($c)=fixture();
    my $prod=GP_State($c,'Geo.Test',0); $prod->{phase}='home'; $prod->{last_reason}='production-marker';
    my $debug=GP_State($c,'Geo.Test',1); $debug->{phase}='away'; $debug->{last_reason}='debug-marker';
    for my $mode (qw(active debug disabled)) {
        $defs{'Geo.Test'}{READINGS}{mode}{VAL}=$mode;
        my $snapshot=JSON::PP->new->canonical->encode([$prod,$debug,\%attr,\@commands,\@messages]);
        for my $selector ('','prod','debug') {
            my @selector=length($selector)?($selector):();
            my $text=GeoPresence_Get($c,'GP','explain','Geo.Test',@selector);
            like($text,$selector eq 'debug'?qr/^=== DEBUG ===/:qr/^=== PRODUCTION ===/,'selected view has an explicit banner');
            like($text,qr/Effective mode\s+: \Q$mode\E/,'actual operating mode stays visible');
            like($text,$selector eq 'debug'?qr/Presence\s+: Away/:qr/Presence\s+: Home/,'only selected presence is displayed');
            like($text,qr/\nSTATUS\n------\n  /,'uppercase heading, underline and indented values');
            for my $section ('CONFIGURED RULES','RECENT DECISIONS','PHONE SENSORS','LOCATIONS AND GEOMETRY','ACTUATOR FEEDBACK','TECHNICAL DETAILS') {
                like($text,qr/\n\Q$section\E\n/,'every report includes '.$section);
            }
            like($text,qr/Production evaluation paused/,'default production explains paused evaluation') if $mode eq 'debug' && $selector ne 'debug';
            my $json=JSON::PP::decode_json(GeoPresence_Get($c,'GP','explain','Geo.Test',@selector,'format=json'));
            is($json->{view},$selector eq 'debug'?'debug':'production','JSON identifies the selected view');
            is($json->{state}{last_reason},$selector eq 'debug'?'debug-marker':'production-marker','JSON includes full chosen state');
            ok(!exists($json->{production}) && !exists($json->{debug}),'JSON does not mix or duplicate state pools');
            is(GeoPresence_Get($defs{'Geo.Test'},'Geo.Test','explain',@selector),$text,'resident shortcut produces the same report');
        }
        is(JSON::PP->new->canonical->encode([$prod,$debug,\%attr,\@commands,\@messages]),$snapshot,'query changes neither state pool, attributes nor outputs');
    }
};

subtest 'full reports, uninitialized views and resident dropdowns are read only' => sub {
    my ($c)=fixture();
    my $all=GeoPresence_Get($c,'GP','explain','Geo.Test','debug');
    like($all,qr/DEBUG READINESS.*Geometry-preserving reset\s+: Supported/s,'debug view includes test capabilities');
    like($all,qr/TECHNICAL DETAILS.*Session ID\s+: Not initialized/s,'uninitialized state is labelled explicitly');
    like($all,qr/Not initialized.*no observations/,'uninitialized view does not claim an evaluated absence');
    ok(!exists($c->{helper}{gp}{debug}{'Geo.Test'}),'reading an uninitialized view does not create a simulation');
    my $menu=GeoPresence_Get($c,'GP','?');
    like($menu,qr/\bexplain:select,Geo\.Test,Geo\.Test#prod,Geo\.Test#debug\b/,'controller dropdown includes resident and both selectors');
    like(GeoPresence_Get($defs{'Geo.Test'},'Geo.Test','?'),qr/\bexplain:select,prod,debug\b/,'resident dropdown has production selected first');
    unlike($menu,qr/debugState/,'retired command is absent from discovery');
    like(GeoPresence_Get($c,'GP','debugState','Geo.Test'),qr/Unknown argument/,'retired command is not retained as an alias');
    for my $options (['auto'],['production'],['view=debug'],['detail=all'],['prod','debug']) {
        my $json=JSON::PP::decode_json(GeoPresence_Get($c,'GP','explain','Geo.Test',@$options,'format=json'));
        like($json->{error},qr/Usage:.*\[prod\|debug\]/,'invalid and obsolete selectors give a structured usage error');
    }
    like(GeoPresence_Get($c,'GP','logStatus','debug'),qr/Too many arguments/,'selector is scoped to explain');
    $defs{'Geo.Second'}={NAME=>'Geo.Second',TYPE=>'GeoPresence',SUBTYPE=>'resident',CONTROLLER=>'GP'};
    $defs{'Geo.Other'}={NAME=>'Geo.Other',TYPE=>'GeoPresence',SUBTYPE=>'resident',CONTROLLER=>'Other'};
    config_event('DEFINED Geo.Second');
    my $before=JSON::PP->new->canonical->encode($c->{helper}{gp});
    $menu=GeoPresence_Get($c,'GP','?');
    like($menu,qr/Geo\.Second#debug/,'new resident appears without a controller restart');
    unlike($menu,qr/Geo\.Other/,'another controller resident is not offered');
    is(JSON::PP->new->canonical->encode($c->{helper}{gp}),$before,'updated dropdown leaves resident state untouched');
    delete $defs{'Geo.Second'}; delete $defs{'Geo.Test'};
    config_event('DELETED Geo.Second','DELETED Geo.Test');
    $before=JSON::PP->new->canonical->encode($c->{helper}{gp});
    like(GeoPresence_Get($c,'GP','?'),qr/\bexplain:textField\b/,'empty controller retains usable command discovery');
    is(JSON::PP->new->canonical->encode($c->{helper}{gp}),$before,'dropdown lookup does not allocate state');
    is(scalar @commands,0,'no actuator or ROOMMATE commands'); is(scalar @messages,0,'no notifications');
};

subtest 'Telnet uses separate fields without wrapping text or truncating identifiers' => sub {
    my ($c)=fixture(); my $s=GP_State($c,'Geo.Test',0); $s->{phase}='away'; $s->{door_result}='uncertain';
    delete $attr{'Geo.Test'}{deviceId};
    config_event('DELETEATTR Geo.Test deviceId');
    my $text=GeoPresence_Get($c,'GP','explain','Geo.Test');
    like($text,qr/Configuration invalid/,'configuration problem visible in complete report');
    like($text,qr/deviceId and webhookUser required/,'actual configuration finding is included');
    like($text,qr/Latest door result\s+: Feedback timeout; outcome uncertain/,'uncertain prior feedback visible during another trip');
    like($text,qr/\nFront door\n  Rule: R\.Door\n  Current assessment: /,'each action has its own indented fields');
    my $long='Geo.'.('Location'x80);
    my $note='These words stay on one line without discarding information. ' x 15;
    my $report={title=>'Example',sections=>[{heading=>'Locations',columns=>['Location','Function','Note'],
        rows=>[[$long,'place',$note],['Another location','place','Second note']]}]};
    my $output=GP_RenderReport($report,0);
    is($output,"Example\n\nLOCATIONS\n---------\n$long\n  Function: place\n  Note: $note\n\nAnother location\n  Function: place\n  Note: Second note\n",
        'one field per line, complete identifiers and prose, blank line between entries');
    my $line='define '.$long.' GeoPresence location Geo.Test place';
    is(GP_RenderReport({title=>'Commands',sections=>[{commands=>[$line]}]},0),"Commands\n$line\n",'commands stay intact for copy and paste');
};

subtest 'recent phone decisions retain their actual source without inheriting stale causes' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);advance(40);
    GP_Process($s,$cfg,{kind=>'phone_snapshot',time=>$now-1,received=>$now,generation=>$s->{generation}},$now,$mono);
    is($s->{trace}[-1]{reason},'held phone snapshot; status only','startup snapshot was processed');
    is($s->{trace}[-1]{source},'phone_snapshot','held snapshot records source');
    advance(60);
    GP_Process($s,$cfg,{kind=>'phone_absent',time=>$now-1,received=>$now,generation=>$s->{generation},
        negative_generation=>$s->{phone}{negative_generation},negative_wall=>$now-1,negative_since=>$mono-1,
        qualified_at=>$now-1,qualified_mono=>$mono-1},$now,$mono);
    is($s->{trace}[-1]{reason},'phone absence qualified','phone absence was processed');
    is($s->{trace}[-1]{source},'phone_absent','qualified absence records source');
    ok(!exists($s->{trace_context}),'temporary observation context does not survive processing');
    my $text=GeoPresence_Get($c,'GP','explain','Geo.Test');
    like($text,qr/Decision: phone absence qualified[^\n]*\n  Rule \/ source: phone_absent/,'report attributes absence to its observation');
    like($text,qr/Decision: held phone snapshot; status only\n  Rule \/ source: phone_snapshot/,'report attributes held snapshot to its observation');
    GP_Trace($s,$now,'later internal decision');
    ok(!exists($s->{trace}[-1]{source}),'later unrelated decision does not inherit phone source');
    GP_Trace($s,$now,'actor result',{target=>'door'});
    my $report=GP_RenderReport({sections=>[GP_ReportTrace($s->{trace},5,0)]},0);
    like($report,qr/Decision: later internal decision\n  Rule \/ source: Not recorded/,'unrecorded causes are explicit, never guessed');
    like($report,qr/Decision: actor result\n  Rule \/ source: door/,'actor target supplies context when no rule exists');
};

subtest 'changed Home exit survives as a new suspicion and needs full new phone qualification' => sub {
    my ($c,$cfg)=fixture(); $attr{'Geo.Test'}{phoneSignalMode}='state';
    config_event('ATTR Geo.Test phoneSignalMode state');
    my $dir=tempdir(CLEANUP=>1); $attr{GP}{logFile}="$dir/geo.log"; $attr{GP}{debugLog}=1;
    $cfg=GP_Config($c,'Geo.Test'); my $s=GP_State($c,'Geo.Test',0);
    my $negative=sub {for my $p (qw(p1 p2 p3)) {reading($p,'state','absent',$now);reading($p,'presence','absent',$now);} };
    advance(40);$negative->();GeoPresence_Timer($c);
    advance(180);GeoPresence_Timer($c);
    ok($s->{phone}{qualified},'phone absence already qualified before radius change');
    advance(5);my $exit=$now;my $body=form($cfg,'Home',0,$exit,radius=>150);
    http($c,$body);advance(3);GeoPresence_Timer($c);
    is($s->{trip}{home_exit},$exit,'the geometry-changing exit is kept');
    is($s->{trip}{scope},'local','no old remote evidence transferred');
    ok(!$s->{trip}{armed},'new departure is unconfirmed');
    ok(!$s->{phone}{qualified},'old phone qualification revoked');
    is($s->{phase},'leaving','new departure visible');
    my $trip=$s->{trip}{id};
    advance(5);$negative->();GeoPresence_Timer($c);
    my $start=$s->{phone}{negative_since};
    advance(5);http($c,$body);advance(3);GeoPresence_Timer($c);
    is($s->{trip}{id},$trip,'duplicate departure cannot start another trip');
    is($s->{phone}{negative_since},$start,'duplicate cannot reset the qualification timer');
    advance(179-($mono-$start));GeoPresence_Timer($c);
    ok(!$s->{trip}{armed},'179 seconds after the new negatives is not enough');
    advance(5);GeoPresence_Timer($c);
    ok($s->{trip}{armed},'full new absence window arms the new trip with held negatives');
    is($s->{trip}{away_reason},'Home exit and qualified phone absence','usual departure contract');
    $cfg=GP_Config($c,'Geo.Test');advance(10);my $entry=$now;
    http($c,form($cfg,'Home',1,$entry));advance(1);http($c,form($cfg,'Home',1,$entry,motion=>'walking'));
    advance(3);GeoPresence_Timer($c);
    is($s->{arrival}{motion},'walking','same-batch duplicate supplies missing walking');
    is($s->{arrival}{started},$entry,'wait starts at first receipt');
    ok(!grep(/^(?:door|garage) /,@commands),'no opening on provisional arrival');
    advance(55);actor_fresh();GeoPresence_Timer($c);
    ok(!grep(/^(?:door|garage) /,@commands),'no opening before 60 second walking wait');
    advance(1);actor_fresh();GeoPresence_Timer($c);
    is_deeply([grep {/^(?:door|garage) /} @commands],['door lock unlocked'],'one door command and no garage');
    http($c,form($cfg,'Home',1,$entry,motion=>'walking'));advance(3);GeoPresence_Timer($c);
    is_deeply([grep {/^(?:door|garage) /} @commands],['door lock unlocked'],'late duplicate cannot open again');
    my ($reset)=grep {$_->{reason} eq 'geometry learned or changed; trip and pending actions revoked'} @{$s->{trace}};
    is($reset->{observed},$exit,'geometry log uses actual exit date, not older phone date');
    is($reset->{zone},'Z.Home','geometry log identifies changed zone');
    like($reset->{geometry_changes},qr/radius: 50 -> 150/,'old and new radius available');
    my $log=join('',diagnostic_lines($c));
    like($log,qr/"geometry_changes":"radius: 50 -> 150"/,'geometry values reach the diagnostic file');
    like($log,qr/Home departure pending after geometry update; new departure confirmation required/,'new qualification explained');
};

subtest 'geometry changes cannot carry an armed trip or authorize Home entry' => sub {
    for my $entry (0,1) {
        my ($c,$cfg,$s)=pending_fixture('unknown');my $old=$s->{trip}{id};
        advance(5);http($c,form($cfg,'Home',$entry,$now,radius=>150));advance(3);GeoPresence_Timer($c);
        ok(!$s->{arrival},'previous pending opening revoked');
        ok(!$s->{trip} || !$s->{trip}{armed},'old armed permission revoked');
        if (!$entry) {isnt($s->{trip}{id},$old,'exit starts a different trip');is($s->{trip}{scope},'local','remote scope removed');}
        else {ok(!$s->{trip},'geometry-changing Home entry starts no trip');}
        advance(70);actor_fresh();GeoPresence_Timer($c);
        ok(!grep(/^(?:door|garage) /,@commands),'waiting alone cannot create a permission');
    }
};

subtest 'new geometry departure still rejects a GPS jump and local positive evidence' => sub {
    for my $positive (0,1) {
        my ($c,$cfg)=fixture();advance(40);
        http($c,form($cfg,'Home',0,$now,radius=>150));advance(3);GeoPresence_Timer($c);
        my $s=GP_State($c,'Geo.Test',0);ok($s->{trip} && !$s->{trip}{armed},'unconfirmed suspicion');
        advance(10);
        if ($positive) {
            reading('p1','state','present',$now);reading('p1','presence','present',$now);GeoPresence_Timer($c);
            ok(!$s->{trip},'new local presence disproves the departure');
        }
        $cfg=GP_Config($c,'Geo.Test');http($c,form($cfg,'Home',1,$now,motion=>'walking'));advance(3);GeoPresence_Timer($c);
        advance(70);actor_fresh();GeoPresence_Timer($c);
        ok(!grep(/^(?:door|garage) /,@commands),'short jump never opens');
    }
};

subtest 'geometry-only profile needs new independent distance evidence after changed Home exit' => sub {
    my ($c,$cfg)=fixture();$attr{'Geo.Test'}{sourceMode}='geofency_only';
    delete @{$attr{'Geo.Test'}}{qw(phoneProxies phoneSignalMode)};
    advance(40);http($c,form($cfg,'Home',0,$now,radius=>150));advance(3);GeoPresence_Timer($c);
    my $s=GP_State($c,'Geo.Test',0);ok($s->{trip} && !$s->{trip}{armed},'Home exit alone stays unconfirmed');
    advance(180);GeoPresence_Timer($c);ok(!$s->{trip}{armed},'time cannot arm geofency_only');
    $cfg=GP_Config($c,'Geo.Test');http($c,form($cfg,'Outer',0,$now));advance(3);GeoPresence_Timer($c);
    ok($s->{trip}{armed},'new outer exit supplies independent distance');
    advance(90);http($c,form($cfg,'Home',1,$now,motion=>'walking'));advance(3);GeoPresence_Timer($c);
    advance(57);actor_fresh();GeoPresence_Timer($c);
    is_deeply([grep {/^(?:door|garage) /} @commands],['door lock unlocked'],'confirmed walk opens only door');
};

subtest 'same-batch newer phone presence vetoes a geometry-changing departure' => sub {
    my ($c,$cfg)=fixture();advance(40);
    my $exit=form($cfg,'Home',0,$now,radius=>150);http($c,$exit);advance(1);
    reading('p1','state','present',$now);reading('p1','presence','present',$now);
    advance(3);GeoPresence_Timer($c);my $s=GP_State($c,'Geo.Test',0);
    ok(!$s->{trip},'positive sampled before geometry reset still disproves departure');
    like($s->{last_reason},qr/contradicted by newer phone presence/,'veto explained');
    advance(10);http($c,$exit);advance(3);GeoPresence_Timer($c);
    ok(!$s->{trip},'retry cannot revive the rejected departure');
    for (1..4) {advance(60);for my $p (qw(p1 p2 p3)) {reading($p,'state','absent',$now);reading($p,'presence','absent',$now);}GeoPresence_Timer($c);}
    ok(!$s->{trip},'later absence cannot restore a disproved Home exit');
};

subtest 'invalid, conflicting and stale geometry cannot seed a departure' => sub {
    for my $case (qw(invalid conflict old returned)) {
        my ($c,$cfg)=fixture();advance(40);my $time=$now;
        if ($case eq 'old') {advance(10);process(GP_State($c,'Geo.Test',0),$cfg,'Home',1);}
        http($c,form($cfg,'Home',0,$time,radius=>$case eq 'invalid'?5000:150));
        http($c,form($cfg,'Home',1,$time,radius=>150)) if $case eq 'conflict';
        if ($case eq 'returned') {advance(1);http($c,form($cfg,'Home',1,$now,radius=>150));}
        advance(3);GeoPresence_Timer($c);my $s=GP_State($c,'Geo.Test',0);
        ok(!$s->{trip},"$case geometry batch leaves no new trip");
        ok(!grep(/^(?:door|garage) /,@commands),"$case geometry cannot issue an opening");
    }
};

subtest 'later duplicate enriches motion without replaying rules or refreshing observation time' => sub {
    for my $motion (qw(walking automotive)) {
        my ($c,$cfg,$s)=pending_fixture('unknown');my $original={%{$s->{arrival}{event}}};
        my $start=$s->{arrival}{start_mono};advance(5);
        GP_Process($s,$cfg,{%$original,motion=>$motion,received=>$now},$now,$mono);
        is($s->{arrival}{motion},$motion,'missing motion filled by later duplicate');
        is($s->{motion_time},$original->{time},'motion timestamp stays original');
        is($s->{arrival}{started},$original->{received},'first receipt retained');
        is($s->{arrival}{due_mono},$start+($motion eq 'walking'?60:10),'deadline relative to first receipt');
        is(scalar @{$s->{intents}},0,'enrichment emits no rule actions');
        my $opposite=$motion eq 'walking'?'automotive':'walking';advance(1);
        GP_Process($s,$cfg,{%$original,motion=>$opposite,received=>$now},$now,$mono);
        is($s->{arrival}{motion},$motion,'duplicate cannot overwrite already known motion');
        complete_arrival($s,$cfg);
        is_deeply([map {$_->{kind}} @{$s->{intents}}],$motion eq 'walking'?['door_open']:['door_open','garage_open'],'expected actions once');
        GP_Process($s,$cfg,{%$original,motion=>$motion,received=>$now},$now,$mono);
        ok(!$s->{trip} && !$s->{arrival},'completed trip not revived');
        is(scalar @{$s->{intents}},0,'completed arrival not replayed');
    }
    my ($c,$cfg,$s)=pending_fixture('unknown');my $original={%{$s->{arrival}{event}}};advance(31);
    GP_Process($s,$cfg,{%$original,motion=>'automotive',received=>$now},$now,$mono);
    is($s->{arrival}{motion},'unknown','late motion is too old for fast arrival wait');
    is($s->{arrival}{wait},60,'receipt does not refresh fast-motion freshness');
    advance(1);process($s,$cfg,'Home',0);
    GP_Process($s,$cfg,{%$original,motion=>'walking',received=>$now},$now,$mono);
    ok(!$s->{arrival},'exit cancellation is not undone by enriched duplicate');
};

subtest 'same-batch motion enrichment precedes phone confirmation' => sub {
    for my $rich_first (0,1) {
        my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);advance(40);process($s,$cfg,'Work',0);advance(90);
        my $time=$now;
        http($c,form($cfg,'Home',1,$time,($rich_first?(motion=>'walking'):())));
        http($c,form($cfg,'Home',1,$time,($rich_first?():(motion=>'walking'))));
        advance(1);reading('p1','state','present',$now);reading('p1','presence','present',$now);
        advance(3);actor_fresh();GeoPresence_Timer($c);
        is_deeply([grep {/^(?:door|garage) /} @commands],['door lock unlocked'],"walking veto applied before phone confirms, rich_first=$rich_first");
    }
};

subtest 'timer profiling attributes synchronous actuator, reading and log delays without double counting' => sub {
    my ($c,$cfg,$s)=pending_fixture('walking');
    my $dir=tempdir(CLEANUP=>1);$attr{GP}{logFile}="$dir/profile.log";$attr{GP}{debugLog}=1;
    my $end=\&readingsEndUpdate;my $write=\&GP_WriteLog;my $writes=0;
    advance(60);actor_fresh();
    $on_command=sub {advance(0.7) if $_[0] eq 'door lock unlocked'};
    {
        no warnings 'redefine';
        local *readingsEndUpdate=sub {advance(0.2) if $_[0]{NAME} eq 'Geo.Test';return $end->(@_)};
        local *GP_WriteLog=sub {$writes++;advance(0.04);return $write->(@_)};
        GeoPresence_Timer($c);
    }
    my $stats=JSON::PP::decode_json(GeoPresence_Get($c,'GP','timerStats','format=json'));
    my $run=$stats->{last_run};my %phases=map {($_->{phase}.'|'.$_->{target})=>$_} @{$run->{phases}};
    is($run->{slowest_phase},'actor_command','slowest call names external actor dispatch');
    is($run->{slowest_target},'door','target is the actual device, not just the controller');
    is($phases{'actor_command|door'}{self_ms},700,'actor callback delay measured');
    is($phases{'resident_reading_callbacks|Geo.Test'}{self_ms},200,'reading callback delay measured separately');
    is($phases{'dispatch|Geo.Test (production)'}{self_ms},0,'parent dispatch excludes command and log children');
    cmp_ok(abs($run->{elapsed_ms}-(900+40*$writes)),'<',0.01,'total includes all synchronous work and its own diagnostic write');
    is($phases{'diagnostic_file|GP'}{calls},$writes,'all writes counted, including timer_slow');
    my $sum=0;$sum+=$_->{self_ms} for @{$run->{phases}};
    cmp_ok(abs($sum-$run->{elapsed_ms}),'<',0.01,'nested time is not counted twice');
    is_deeply([grep {/^(?:door|garage) /} @commands],['door lock unlocked'],'profiling leaves commands unchanged');
    my ($line)=grep {/GeoPresence timer_slow/} diagnostic_lines($c);
    like($line,qr/"slowest_phase":"actor_command"/,'slow diagnostic identifies callback');
    like($line,qr/"slowest_target":"door"/,'slow diagnostic includes device');
    ok(!grep(/timer_slow/,map {$_->[2]} @logs),'structured timing stays out of FHEM log');
    my $text=GeoPresence_Get($c,'GP','timerStats');
    like($text,qr/SLOWEST PROFILED RUN/,'human-readable timing evidence available');
    like($text,qr/actor_command/,'human-readable report names measured actor step');
    my $snapshot=JSON::PP->new->canonical->encode($c->{helper}{gp_timer_stats});
    GeoPresence_Get($c,'GP','timerStats','format=json');
    is(JSON::PP->new->canonical->encode($c->{helper}{gp_timer_stats}),$snapshot,'statistics query never changes its history');
};

subtest 'timer profiling keeps bounded slow and late histories independent of log settings' => sub {
    my ($c)=fixture();$attr{GP}{debugLog}=0;my $validate=\&GP_Validate;
    my $old_start;
    {
        no warnings 'redefine';
        local *GP_Validate=sub {advance(0.6);return $validate->(@_)};
        for (1..16) {advance(2);$old_start=$now if $_==5;GeoPresence_Timer($c);}
    }
    my $stats=JSON::PP::decode_json(GeoPresence_Get($c,'GP','timerStats','format=json'));
    is(scalar @{$stats->{recent_slow}},12,'bounded slow-run history');
    is(scalar @{$stats->{recent_late}},12,'bounded delayed-start history');
    is($stats->{recent_slow}[0]{started_at},$old_start,'only oldest samples pruned');
    is($stats->{recent_slow}[-1]{slowest_phase},'validation','slow step retained without file output');
    is($stats->{recent_slow}[-1]{slowest_target},'Geo.Test','configuration owner retained');
    my $worst=$stats->{worst_run};advance(2);GeoPresence_Timer($c);
    $stats=JSON::PP::decode_json(GeoPresence_Get($c,'GP','timerStats','format=json'));
    is($stats->{last_run}{elapsed_ms},0,'subsequent quick run measured independently');
    is_deeply($stats->{worst_run},$worst,'slowest evidence survives faster runs');
    is($stats->{recent_late}[-1]{elapsed_ms},0,'late start is captured alongside its fast execution');
    is($stats->{recent_late}[-1]{start_lag_ms},1000,'scheduled start lateness stays separate');
    is($stats->{slow_runs},16,'quick late call is not counted as slow work');
    GP_ResetController($c);
    is_deeply(JSON::PP::decode_json(GeoPresence_Get($c,'GP','timerStats','format=json'))->{worst_run},$worst,'evidence survives session reset');
};

subtest 'profiling preserves Perl context and exceptions and stays passive outside a timer' => sub {
    my ($c)=fixture();my @contexts;
    my $call=sub {push @contexts,!defined(wantarray)?'void':wantarray?'list':'scalar';return (1,2)};
    my @list=GP_Profile($c,'test','target',$call);my $scalar=GP_Profile($c,'test','target',$call);GP_Profile($c,'test','target',$call);
    is_deeply(\@list,[1,2],'unprofiled list return unchanged');is($scalar,2,'unprofiled scalar return unchanged');
    is_deeply(\@contexts,[qw(list scalar void)],'unprofiled context preserved');
    ok(!exists($c->{helper}{gp_work}),'external call does not create a profile');
    local $c->{helper}{gp_work}={};@contexts=();
    @list=GP_Profile($c,'test','target',$call);$scalar=GP_Profile($c,'test','target',$call);GP_Profile($c,'test','target',$call);
    is_deeply(\@contexts,[qw(list scalar void)],'profiled context preserved');
    is_deeply(\@list,[1,2],'profiled list return unchanged');is($scalar,2,'profiled scalar return unchanged');
    eval {GP_Profile($c,'test','target',sub {advance(0.1);die "original exception\n"})};
    is($@,"original exception\n",'original error propagated to existing error handler');
    cmp_ok(abs($c->{helper}{gp_work}{phases}{'test|target'}{self_ms}-100),'<',0.001,'exception path still measured');
};

sub saved_trip_fixture {
    my ($scope)=@_;
    my ($c,$cfg)=fixture(); my $s=GP_State($c,'Geo.Test',0);
    actor_fresh(); advance(40);
    if ($scope eq 'local') {
        process($s,$cfg,'Home',0); advance(1);
        my $first=negative_samples(); phone_tick($s,$cfg,$first); advance(181);
        phone_tick($s,$cfg,negative_samples());
    } else { process($s,$cfg,'Work',1); }
    GP_Publish($c,'Geo.Test',$cfg,$s);
    die 'checkpoint fixture not armed' unless $s->{trip}{armed};
    @commands=(); @messages=();
    return ($c,$cfg,$s);
}

sub simulate_process_restart {
    my ($c)=@_;
    advance(300);
    # fhem.save restores readings, not helper references or monotonic clocks.
    delete $c->{helper}{gp}; $mono=5;
    GP_ResetController($c,'resume');
    GeoPresence_Timer($c);
    return (GP_Config($c,'Geo.Test'),GP_State($c,'Geo.Test',0));
}

subtest 'fresh contexts do not reuse trip IDs when clocks and startup counters repeat' => sub {
    my ($c)=fixture();
    my %ids;
    for (1..3) {
        my $s=new_state();
        my $trip=GP_StartTrip($s,ev('Home',0,$now),'local');
        ok(!$ids{$trip->{id}}++,'fresh context has a new trip ID at identical wall and monotonic times');
        is(GP_StartTrip($s,ev('Outer',0,$now),'remote'),$trip,'existing trip keeps its identity');
        is($s->{seq},1,'reusing an open trip does not advance the local counter');
        delete $s->{trip};
        my $next=GP_StartTrip($s,ev('Home',0,$now),'local');
        ok(!$ids{$next->{id}}++,'next trip in the same context also has a new ID');
        is($s->{seq},2,'new trip advances only the local counter');
        like($next->{id},qr/\A[A-Za-z0-9_.:\-]{1,256}\z/,'new ID fits the existing checkpoint contract');
    }
    my $prod=GP_State($c,'Geo.Test',0);
    my $prod_id=GP_StartTrip($prod,ev('Home',0,$now),'local')->{id};
    for (1..2) {
        is(GeoPresence_Set($c,'GP','debugReset','Geo.Test'),
            'Debug session reset; no productive changes','debug reset succeeds without advancing either clock');
        my $debug=GP_State($c,'Geo.Test',1);
        my $id=GP_StartTrip($debug,ev('Home',0,$now),'local')->{id};
        ok(!$ids{$id}++ && $id ne $prod_id,'each debug reset gets its own trip identity');
        is($prod->{trip}{id},$prod_id,'debug reset preserves the productive trip');
    }
    my $long=GP_NewState($now,$mono,'1:prod:'.('r'x230).':0');
    cmp_ok(length(GP_StartTrip($long,ev('Home',0,$now),'local')->{id}),'<=',256,
        'long device names do not exceed the existing checkpoint ID limit');
};

subtest 'clock revocations keep each context and its later trip IDs bounded' => sub {
    for my $debug (0,1) {
      for my $legacy (0,1) {
        my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',$debug);
        $s->{generation}.=':clock' x 40 if $legacy;
        my %contexts=($s->{generation}=>1);my %trips;
        my ($bounded,$unique,$trip_bounded)=(1,1,1);
        for (1..64) {
            $now+=60;$mono+=1;GP_CheckClock($s,$cfg,$now,$mono);
            $bounded=0 unless $s->{generation} =~ /\A[0-9a-f]{64}\z/;
            $unique=0 if $contexts{$s->{generation}}++;
            my $trip=GP_StartTrip($s,ev('Home',0,$now),'local');
            $trip_bounded=0 if length($trip->{id})>256;
            $unique=0 if $trips{$trip->{id}}++;
        }
        ok($bounded,"debug=$debug, legacy=$legacy: every clock reset produces a bounded context");
        ok($unique,'revoked contexts and later trip IDs are never reused');
        ok($trip_bounded,'later trip IDs remain within the existing checkpoint limit');
        is($s->{output_revision},64,'every clock reset still revokes output permissions');
        ok(!@{$s->{intents}} && !$s->{arrival},'clock resets preserve no output or pending arrival');
      }
    }
};

subtest 'new trips remain restorable after repeated clock corrections' => sub {
    for my $corrections (32,64) {
        my ($c,$cfg,$s)=saved_trip_fixture('remote');my $old_id=$s->{trip}{id};
        for (1..$corrections) {$now+=60;$mono+=1;GP_CheckClock($s,$cfg,$now,$mono);}
        ok(!$s->{trip},'the old trip is revoked');
        GP_Publish($c,'Geo.Test',$cfg,$s);
        is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none',
            'the revoked trip cannot remain a qualified checkpoint');
        advance(40);process($s,$cfg,'Work',1);GP_Publish($c,'Geo.Test',$cfg,$s);
        my $saved=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
        is($saved->{status},'qualified',"$corrections corrections: a new departure is saved");
        isnt($saved->{trip}{id},$old_id,'the new trip has a different identity');
        cmp_ok(length($saved->{trip}{id}),'<=',256,'the saved trip fits the unchanged reader limit');
        my $id=$saved->{trip}{id};my $away=$saved->{trip}{away_time};
        ($cfg,$s)=simulate_process_restart($c);
        is($s->{resume}{status},'restored','the new trip is restored after restart');
        is(($s->{trip}//{})->{id},$id,'restoration keeps the saved trip ID');
        is(($s->{trip}//{})->{away_time},$away,'restoration keeps the original absence evidence');
        ok(!$s->{arrival} && !@{$s->{intents}},'restart creates no pending arrival or output');
        is(scalar @commands,0,'restart alone issues no device command');
        advance(40);arrive($s,$cfg,'walking');actor_fresh();GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        is_deeply([grep {/^(?:door|garage) /} @commands],['door lock unlocked'],
            'only a new qualified return can open, and walking still excludes the garage');
    }
};

subtest 'a restored legacy ID is retained while subsequent trips use the new session' => sub {
    for my $version (1,2) {
        my ($c,$cfg,$s)=saved_trip_fixture('remote');
        my $cp=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
        my $id=$cp->{trip}{id}='1:prod:Geo.Test:0:1';
        $cp->{version}=$version;
        if ($version==1) {
            delete $cp->{state}{action_visits};
            $cp->{state}{notify_seen}={'A.Msg|enter|1|group:Work'=>1};
            $cp->{state}{notify_order}=['A.Msg|enter|1|group:Work'];
            $cp->{state}{notify_last}=delete $cp->{state}{action_last};
        }
        reading('Geo.Test','gp_trip_checkpoint',JSON::PP::encode_json($cp),$now);
        ($cfg,$s)=simulate_process_restart($c);
        is($s->{resume}{status},'restored',"version $version checkpoint accepted");
        is($s->{trip}{id},$id,'restored trip keeps the saved ID');
        is($s->{trip}{away_time},$cp->{trip}{away_time},'restoration keeps the original departure evidence');
        ok(!$s->{arrival} && !@{$s->{intents}},'restoration creates no pending action');
        is(scalar @commands,0,'restart alone dispatches no command');
        advance(40); arrive($s,$cfg,'walking'); GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        is(scalar(grep {/^door /} @commands),1,'new return completes the restored trip once');
        ok(!$s->{trip},'completed trip is closed');
        advance(61); process($s,$cfg,'Work',1); GP_Checkpoint($c,'Geo.Test',$cfg,$s);
        ok($s->{trip}{armed},'new distance observation authorizes a genuinely new trip');
        isnt($s->{trip}{id},$id,'new trip cannot reuse the restored legacy ID');
        is_deeply($s->{trip}{actions},{},'new trip starts with its own unconsumed actions');
        my $new=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
        is($new->{trip}{id},$s->{trip}{id},'new checkpoint contains the new trip ID');
        is($new->{version},2,'ID change needs no new checkpoint format');
    }
};

sub checkpoint_work {
    my ($call)=@_;
    my ($encodes,$writes)=(0,0);
    my $encode=JSON::PP->can('encode'); my $set=\&setReadingsVal;
    no warnings qw(redefine once);
    local *JSON::PP::encode=sub {
        $encodes++ if ref($_[1]) eq 'HASH' && exists($_[1]{version}) && exists($_[1]{status});
        return $encode->(@_);
    };
    local *setReadingsVal=sub {
        $writes++ if $_[0]{NAME} eq 'Geo.Test' && $_[1] eq 'gp_trip_checkpoint';
        return $set->(@_);
    };
    $call->();
    return [$encodes,$writes];
}

subtest 'diagnostics, rejected observations and unchanged retries do no checkpoint work' => sub {
    my ($c,$cfg,$s)=saved_trip_fixture('remote');
    my $before={%{$defs{'Geo.Test'}{READINGS}{gp_trip_checkpoint}}};
    my $observed=$s->{zones}{'Z.Work'}{time};
    $s->{intents}=[];
    for my $case (
        ['idle',sub {}],
        ['diagnostic',sub {GP_Trace($s,$now,'diagnostic only',{diagnostic_only=>1})}],
        ['decision trace',sub {GP_Trace($s,$now,'nothing changed')}],
        ['actuator result',sub {$s->{door_result}='confirmed';GP_Trace($s,$now,'actor feedback')}],
        ['identical retry',sub {
            my $e=ev('Work',1,$observed); $e->{received}=$now;
            GP_Process($s,$cfg,$e,$now,$mono);
        }],
        ['expired event',sub {
            my $e=ev('Work2',1,$now-$cfg->{action_max_age}-1); $e->{received}=$now;
            GP_Process($s,$cfg,$e,$now,$mono);
        }],
        ['ordinary timer',sub {GeoPresence_Timer($c)}],
    ) {
        advance(1);
        is_deeply(checkpoint_work(sub {
            $case->[1]->(); GP_Dispatch($c,'Geo.Test',$cfg,$s,0); GP_Publish($c,'Geo.Test',$cfg,$s);
        }),[0,0],"$case->[0] neither serializes nor writes the checkpoint");
    }
    is_deeply($defs{'Geo.Test'}{READINGS}{gp_trip_checkpoint},$before,'saved value and reading timestamp stay unchanged');
};

subtest 'accepted travel observations persist memberships, exits and visit consumption once' => sub {
    my ($c,$cfg,$s)=saved_trip_fixture('remote');
    my $id=$s->{trip}{id}; my $away=$s->{trip}{away_time};
    advance(1); process($s,$cfg,'Work',0);
    is_deeply(checkpoint_work(sub {
        GP_Checkpoint($c,'Geo.Test',$cfg,$s); GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    }),[1,1],'new exit is encoded and written once');
    my $cp=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
    is($cp->{trip}{exits}{'group:Work'},$now,'explicit group exit persisted');
    is($cp->{state}{members}{'Z.Work'}{entry},0,'explicit membership persisted');
    advance(301); process($s,$cfg,'Work',1);
    is_deeply(checkpoint_work(sub {GP_Dispatch($c,'Geo.Test',$cfg,$s,0); GP_Publish($c,'Geo.Test',$cfg,$s)}),
        [1,1],'new visit and notification consumption share one checkpoint before dispatch');
    $cp=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
    is($cp->{state}{zone_visits}{'Z.Work'},2,'new location visit persisted');
    is($cp->{state}{group_visits}{Work},2,'new group visit persisted');
    is($cp->{state}{action_last}{'A.Msg'},$now,'notification cooldown persisted');
    is_deeply($cp->{state}{action_visits},{'A.Msg|enter|group:Work'=>2},'only the latest consumed visit retained');
    ok(!exists($cp->{trip}{exits}{'group:Work'}),'reentry removed the prior exit');
    is($cp->{trip}{id},$id,'trip identity unchanged');
    is($cp->{trip}{away_time},$away,'saving did not renew the departure');
    ($cfg,$s)=simulate_process_restart($c);
    is($s->{group_visits}{Work},2,'latest visit recovered after restart');
    is($s->{action_last}{'A.Msg'},$cp->{state}{action_last}{'A.Msg'},'cooldown recovered after restart');
    is(scalar @messages,1,'restart did not repeat the notification');
};

subtest 'opening consumption is saved while duplicate rules leave it unchanged' => sub {
    my ($c,$cfg,$s)=saved_trip_fixture('remote'); advance(70);
    $s->{intents}=[];
    my $e=ev('Home',1,$now,'automotive');
    GP_Rules($s,$cfg,'arrival',$e,$now,$mono);
    is(scalar @{$s->{intents}},2,'both opening actions consumed');
    is_deeply(checkpoint_work(sub {GP_Checkpoint($c,'Geo.Test',$cfg,$s)}),[1,1],'consumed actions persisted');
    my $before=GP_Read('Geo.Test','gp_trip_checkpoint','');
    advance(1);
    is_deeply(checkpoint_work(sub {
        GP_Rules($s,$cfg,'arrival',$e,$now,$mono); GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    }),[0,0],'already consumed actions do no checkpoint work');
    is(GP_Read('Geo.Test','gp_trip_checkpoint',''),$before,'duplicate rules did not change consumption counters');
    ($cfg,$s)=simulate_process_restart($c);
    advance(40); arrive($s,$cfg,'automotive'); GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
    is(scalar(grep {/^(?:door|garage) /} @commands),0,'restart cannot repeat consumed opening actions');
};

subtest 'motion supplements and delayed revocations update the saved evidence' => sub {
    my ($c,$cfg,$s)=saved_trip_fixture('remote');
    advance(70); process($s,$cfg,'Drive',1); my $approach=$now;
    GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    advance(1);
    my $e=ev('Drive',1,$approach,'automotive'); $e->{received}=$now;
    is_deeply(checkpoint_work(sub {
        GP_Process($s,$cfg,$e,$now,$mono); GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    }),[1,1],'accepted movement supplement persisted');
    my $cp=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
    is($cp->{state}{motion},'automotive','supplemented motion saved');
    is($cp->{state}{automotive},$approach,'original motion time retained');
    advance(1); process($s,$cfg,'Home',1); GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    my $position=$s->{position_time};
    advance(1); $e=ev('Drive',0,$approach+1); $e->{received}=$now;
    is_deeply(checkpoint_work(sub {
        GP_Process($s,$cfg,$e,$now,$mono); GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    }),[1,1],'delayed exit persisted the revoked movement evidence');
    $cp=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
    ok(!exists($cp->{state}{motion}) && !exists($cp->{state}{automotive}),'revoked movement is absent from checkpoint');
    is($cp->{state}{position_time},$position,'delayed exit did not rewind the saved position');
    is($cp->{status},'qualified','the valid Home arrival kept its trip');
};

subtest 'expired movement and display data are checkpointed once without inventing exits' => sub {
    my ($c,$cfg,$s)=saved_trip_fixture('remote');
    advance(70); process($s,$cfg,'Drive',1,'automotive'); GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    advance($cfg->{approach_timeout}+1);
    is_deeply(checkpoint_work(sub {
        GP_TickState($s,$cfg,$now,$mono); GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    }),[1,1],'approach timeout persisted removal of saved movement');
    my $cp=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
    ok(!exists($cp->{state}{automotive}) && !exists($cp->{state}{motion}),'expired approach movement removed');
    advance(1);
    is_deeply(checkpoint_work(sub {
        GP_TickState($s,$cfg,$now,$mono); GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    }),[0,0],'completed timeout did not cause another write');
    advance($cfg->{zone_display_max_age});
    is_deeply(checkpoint_work(sub {
        GP_TickState($s,$cfg,$now,$mono); GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    }),[1,1],'display expiry persisted once');
    $cp=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
    is($cp->{state}{zones}{'Z.Drive'}{entry},1,'accepted entry retained after display expiry');
    is($cp->{state}{location},'unknown','expired location saved');
    is($cp->{state}{members}{'Z.Drive'}{entry},1,'explicit membership retained');
    ok(!exists($cp->{trip}{exits}{'location:Z.Drive'}),'display expiry did not invent an explicit exit');
    advance(1);
    is_deeply(checkpoint_work(sub {
        GP_TickState($s,$cfg,$now,$mono); GP_Trace($s,$now,'diagnostic after expiry');
        GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    }),[0,0],'already expired display remained quiet');
    ($cfg,$s)=simulate_process_restart($c);
    is($s->{location},'unknown','restart retained the expired display');
    is($s->{zones}{'Z.Drive'}{entry},1,'restart retained the accepted zone evidence');
    is($s->{members}{'Z.Drive'}{entry},1,'restart retained the explicit membership');
};

subtest 'losing qualification invalidates a clean checkpoint even with blocked outputs' => sub {
    for my $cause (qw(trip armed conflict phase geometry)) {
        my ($c,$cfg,$s)=saved_trip_fixture('remote');
        $c->{helper}{gp}{ready}=0;
        if ($cause eq 'trip') {delete $s->{trip};}
        elsif ($cause eq 'armed') {$s->{trip}{armed}=0;}
        elsif ($cause eq 'conflict') {$s->{conflict}=1;}
        elsif ($cause eq 'phase') {$s->{phase}='home';}
        else {$cfg={%$cfg,geometry_ready=>0};}
        is_deeply(checkpoint_work(sub {GP_Publish($c,'Geo.Test',$cfg,$s)}),[1,1],"$cause revoked the saved permission without a trace");
        is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none',"$cause left no qualified checkpoint");
        is(scalar @commands,0,'revocation emitted no command');
        advance(1); GP_Trace($s,$now,'still revoked');
        is_deeply(checkpoint_work(sub {GP_Publish($c,'Geo.Test',$cfg,$s)}),[0,0],'revoked checkpoint was not rewritten for diagnostics');
    }
};

subtest 'restored checkpoints stay unchanged and externally edited readings are repaired' => sub {
    my ($c,$cfg,$s)=saved_trip_fixture('remote');
    my $before={%{$defs{'Geo.Test'}{READINGS}{gp_trip_checkpoint}}};
    is_deeply(checkpoint_work(sub {($cfg,$s)=simulate_process_restart($c)}),[0,0],'process restart did not re-encode unchanged travel data');
    is_deeply($defs{'Geo.Test'}{READINGS}{gp_trip_checkpoint},$before,'restart retained saved_at and the reading timestamp');
    advance(1);
    is_deeply(checkpoint_work(sub {GP_ResetController($c,'resume'); GeoPresence_Timer($c)}),[0,0],'module reload also preserved the unchanged checkpoint');
    $cfg=GP_Config($c,'Geo.Test'); $s=GP_State($c,'Geo.Test',0);
    reading('Geo.Test','gp_trip_checkpoint','{',$now);
    is_deeply(checkpoint_work(sub {GP_Checkpoint($c,'Geo.Test',$cfg,$s)}),[1,1],'changed reading repaired from the live validated trip');
    my $cp=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
    is($cp->{status},'qualified','repaired checkpoint is usable');
    is($cp->{trip}{id},$s->{trip}{id},'repair retained the live trip identity');
    advance(1); GP_Trace($s,$now,'diagnostic after repair');
    is_deeply(checkpoint_work(sub {GP_Checkpoint($c,'Geo.Test',$cfg,$s)}),[0,0],'repair did not cause repeated writes');
};

subtest 'thousands of visits retain one consumption slot and a small recoverable checkpoint' => sub {
    my ($c)=fixture(); mode('GP','debug'); attribute('R.Work','cooldown',0);
    mode('GP','active'); GeoPresence_Timer($c);
    my $cfg=GP_Config($c,'Geo.Test'); my $s=GP_State($c,'Geo.Test',0); advance(40);
    process($s,$cfg,'Work',1); GP_Publish($c,'Geo.Test',$cfg,$s);
    my $initial=length(GP_Read('Geo.Test','gp_trip_checkpoint',''));
    for (1..2100) {
        advance(1); process($s,$cfg,'Work',0);
        advance(1); process($s,$cfg,'Work',1);
    }
    GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    my $raw=GP_Read('Geo.Test','gp_trip_checkpoint',''); my $cp=JSON::PP::decode_json($raw);
    is($cp->{version},2,'compact checkpoint format written');
    is($cp->{status},'qualified','long-running ordinary activity did not discard the trip');
    is_deeply($s->{action_visits},{'A.Msg|enter|group:Work'=>2101},'one slot replaces all 2101 consumed visits');
    is_deeply($s->{action_last},{'A.Msg'=>$now},'one cooldown per action');
    ok(!exists($s->{notify_seen}) && !exists($s->{notify_order}),'no legacy history retained at runtime');
    ok(!exists($cp->{state}{notify_seen}) && !exists($cp->{state}{notify_order}),'no legacy history stored');
    cmp_ok(length($raw),'<',4096,'checkpoint stays below 4 KiB for this configuration');
    cmp_ok(length($raw)-$initial,'<',100,'size grows only with the counter digits, not the number of visits');
    ($cfg,$s)=simulate_process_restart($c);
    ok($s->{trip}{armed},'qualified trip recovered after thousands of visits');
    advance(40); process($s,$cfg,'Work',1);
    is(scalar @{$s->{intents}},0,'same visit cannot repeat after restart even with zero cooldown');
    advance(1); process($s,$cfg,'Work',0); advance(1); process($s,$cfg,'Work',1);
    is(scalar @{$s->{intents}},1,'a genuine new visit still schedules the action');
};

sub consumption_fixture {
    my ($c)=fixture(); mode('GP','debug'); attribute('R.Work','cooldown',0);
    for my $spec ([Route=>'exit'],[ArrivalMsg=>'arrival']) {
        my ($name,$trigger)=@$spec; gp_define('R.'.$name,'rule GP');
        attribute('R.'.$name,'residents','Geo.Test'); attribute('R.'.$name,'trigger',$trigger);
        attribute('R.'.$name,'action','A.Msg'); attribute('R.'.$name,'cooldown',0);
        if ($trigger eq 'exit') {
            attribute('R.'.$name,'locations','Z.Sternensteg'); attribute('R.'.$name,'afterExit','group:Work');
        }
    }
    mode('GP','active'); GeoPresence_Timer($c);
    my $cfg=GP_Config($c,'Geo.Test'); my $s=GP_State($c,'Geo.Test',0); advance(40);
    process($s,$cfg,'Work',1); advance(1); process($s,$cfg,'Work',0);
    advance(1); process($s,$cfg,'Sternensteg',0); advance(70);
    $s->{intents}=[]; GP_Rules($s,$cfg,'arrival',ev('Home',1,$now,'automotive'),$now,$mono);
    GP_Publish($c,'Geo.Test',$cfg,$s); $s->{intents}=[]; @commands=(); @messages=();
    return ($c,$cfg,$s);
}

sub legacy_consumption_checkpoint {
    my ($past)=@_;
    my $cp=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint','')); $cp->{version}=1;
    my $state=$cp->{state}; my $id=$cp->{trip}{id}; my $current=$past+1;
    $state->{zone_visits}{'Z.Work'}=$current; $state->{group_visits}{Work}=$current;
    delete @{$state}{qw(action_visits action_last)};
    $state->{notify_seen}={map {('A.Msg|enter|'.$_.'|group:Work')=>1} 1..$current};
    $state->{notify_seen}{'A.Msg|exit|'.$id.'|location:Z.Sternensteg'}=1;
    $state->{notify_seen}{'A.Msg|arrival|'.$id.'|arrival'}=1;
    $state->{notify_order}=[sort keys %{$state->{notify_seen}}];
    $state->{notify_last}={'A.Msg'=>$now,'A.Obsolete'=>$now};
    $cp->{trip}{actions}={$id.'|door_open|door'=>1,$id.'|garage_open|garage'=>1};
    return $cp;
}

subtest 'version 1 recovery imports current visits, trip consumption and cooldowns once' => sub {
    my ($c,$cfg,$s)=consumption_fixture(); my $id=$s->{trip}{id}; my $away=$s->{trip}{away_time};
    my $cp=legacy_consumption_checkpoint(300);
    reading('Geo.Test','gp_trip_checkpoint',JSON::PP::encode_json($cp),$now);
    is_deeply(checkpoint_work(sub {($cfg,$s)=simulate_process_restart($c)}),[1,1],'legacy recovery rewrites only the compact checkpoint once');
    my $new=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
    is($new->{version},2,'legacy format upgraded');
    is($new->{trip}{id},$id,'original trip identity retained');
    is($new->{trip}{away_time},$away,'original departure time retained');
    is_deeply($new->{trip}{actions},{'door_open|door'=>1,'garage_open|garage'=>1,
        'A.Msg|exit|location:Z.Sternensteg'=>1,'A.Msg|arrival|arrival'=>1},'only current trip consumption imported');
    is_deeply($new->{state}{action_visits},{'A.Msg|enter|group:Work'=>301},'only the current consumed visit imported');
    is_deeply($new->{state}{action_last},{'A.Msg'=>$cp->{state}{notify_last}{'A.Msg'}},'needed cooldown retained, obsolete action dropped');
    ok(!exists($s->{notify_seen}) && !exists($s->{notify_order}) && !exists($s->{notify_last}),'old runtime fields removed');
    advance(1); $s->{intents}=[];
    GP_Rules($s,$cfg,'enter',{zone=>'Z.Work',group=>'Work',selector=>'group:Work',time=>$now,received=>$now},$now,$mono);
    is(scalar @{$s->{intents}},0,'current ordinary visit was not replayed');
    advance(1); process($s,$cfg,'Sternensteg',0);
    is(scalar @{$s->{intents}},0,'current route action was not replayed');
    advance(40); arrive($s,$cfg,'automotive'); GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
    is(scalar @commands,0,'consumed door and garage actions were not replayed');
    is(scalar @messages,0,'consumed arrival notification was not replayed');
};

subtest 'module reload compacts a live oversized legacy history before writing it' => sub {
    my ($c,$cfg,$s)=consumption_fixture(); my $id=$s->{trip}{id}; my $away=$s->{trip}{away_time};
    my $cp=legacy_consumption_checkpoint(1997);
    cmp_ok(length(JSON::PP::encode_json($cp)),'>',65536,'equivalent old history exceeded the checkpoint limit');
    delete @{$s}{qw(action_visits action_last)};
    $s->{$_}=$cp->{state}{$_} for keys %{$cp->{state}};
    $s->{trip}{actions}=$cp->{trip}{actions}; delete $cfg->{consumption_slots};
    GP_ResetController($c,'resume'); GeoPresence_Timer($c);
    $s=GP_State($c,'Geo.Test',0); $cfg=GP_Config($c,'Geo.Test');
    my $raw=GP_Read('Geo.Test','gp_trip_checkpoint',''); my $new=JSON::PP::decode_json($raw);
    is($new->{status},'qualified','live trip saved despite the old oversized history');
    is($new->{version},2,'live state converted before checkpoint encoding');
    is($s->{trip}{id},$id,'live trip survived reload');
    is($s->{trip}{away_time},$away,'reload did not renew departure evidence');
    is_deeply($s->{action_visits},{'A.Msg|enter|group:Work'=>1998},'only the latest visit retained');
    is(scalar(keys %{$s->{trip}{actions}}),4,'opening, route and arrival consumption retained');
    cmp_ok(length($raw),'<',4096,'history replaced by a checkpoint below 4 KiB');
    advance(1); GP_Trace($s,$now,'after legacy reload');
    is_deeply(checkpoint_work(sub {GP_Checkpoint($c,'Geo.Test',$cfg,$s)}),[0,0],'ordinary diagnostics remain free of checkpoint work');
    is(scalar @commands,0,'reload did not dispatch historical commands');
    is(scalar @messages,0,'reload did not dispatch historical notifications');
};

subtest 'malformed or incomplete compact consumption cannot restore a permission' => sub {
    for my $case (qw(missing_visits missing_cooldown missing_actions unknown_visit future_visit fractional_visit unknown_action action_value unknown_cooldown legacy_field)) {
        my ($c,$cfg,$s)=saved_trip_fixture('remote');
        my $cp=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
        if ($case eq 'missing_visits') {delete $cp->{state}{action_visits};}
        elsif ($case eq 'missing_cooldown') {delete $cp->{state}{action_last};}
        elsif ($case eq 'missing_actions') {delete $cp->{trip}{actions};}
        elsif ($case eq 'unknown_visit') {$cp->{state}{action_visits}{'Unknown|enter|group:Work'}=1;}
        elsif ($case eq 'future_visit') {$cp->{state}{action_visits}{'A.Msg|enter|group:Work'}=2;}
        elsif ($case eq 'fractional_visit') {$cp->{state}{action_visits}{'A.Msg|enter|group:Work'}=0.5;}
        elsif ($case eq 'unknown_action') {$cp->{trip}{actions}{'door_open|unknown'}=1;}
        elsif ($case eq 'action_value') {$cp->{trip}{actions}{'door_open|door'}=2;}
        elsif ($case eq 'unknown_cooldown') {$cp->{state}{action_last}{Unknown}=$now;}
        else {$cp->{state}{notify_seen}={};}
        reading('Geo.Test','gp_trip_checkpoint',JSON::PP::encode_json($cp),$now);
        ($cfg,$s)=simulate_process_restart($c);
        is($s->{resume}{status},'rejected',"$case rejected");
        ok(!$s->{trip},'invalid consumption restored no trip');
        is(scalar @commands,0,'invalid checkpoint caused no command');
    }
};

subtest 'qualified local and remote trips survive a process restart and open on a new return' => sub {
    for my $scope (qw(local remote)) {
        my ($c,$cfg,$s)=saved_trip_fixture($scope);
        my $id=$s->{trip}{id}; my $away=$s->{trip}{away_time};
        my $checkpoint=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
        is($checkpoint->{status},'qualified',"$scope trip checkpointed through ordinary reading");
        ok(!exists($checkpoint->{state}{arrival}) && !exists($checkpoint->{state}{intents}), 'checkpoint contains no pending operations');
        ($cfg,$s)=simulate_process_restart($c);
        is($s->{resume}{status},'restored',"$scope trip restored");
        is($s->{trip}{id},$id,'same trip ID, not a new authorization');
        is($s->{trip}{away_time},$away,'original departure time retained');
        is($s->{trip}{scope},$scope,'range evidence retained');
        ok(!$s->{arrival} && !@{$s->{intents}},'restart creates no arrival or command');
        is(scalar @commands,0,'restart alone changes no device');
        advance(40); arrive($s,$cfg,$scope eq 'local'?'walking':'automotive');
        GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        is(scalar(grep {/^door /} @commands),1,'door opens using held pre-restart contact');
        is(scalar(grep {/^garage /} @commands),$scope eq 'local'?0:1,'garage follows the original trip scope and new motion');
        is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none','completed trip is checkpointed as consumed');
        @commands=(); ($cfg,$s)=simulate_process_restart($c); advance(40);
        arrive($s,$cfg,'automotive'); GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
        is(scalar @commands,0,'another restart and Home entry cannot replay the consumed trip');
    }
};

subtest 'restart restores prior exits and notification consumption without replaying them' => sub {
    my ($c,$cfg,$s)=saved_trip_fixture('remote');
    advance(5); process($s,$cfg,'Work',0);
    my $exit=$s->{trip}{exits}{'group:Work'};
    GP_Publish($c,'Geo.Test',$cfg,$s);
    ($cfg,$s)=simulate_process_restart($c);
    is(GP_ExitEvidence($s,'group:Work',$now),$exit,'explicit Work exit remains in the same trip');
    is(scalar @messages,0,'restoration sends no historical message');
    ok(keys(%{$s->{action_visits}}),'current notification consumption retained');
    advance(40); arrive($s,$cfg,'walking');
    is(scalar(grep {$_->{kind} eq 'garage_open'} @{$s->{intents}}),0,'fresh walking still vetoes garage after remote restoration');
};

subtest 'corrupt, changed, expired and superseded checkpoints cannot grant a restart permission' => sub {
    for my $case (qw(json version schema future expired identity geometry config roommate phone)) {
        my ($c,$cfg,$s)=saved_trip_fixture('remote');
        my $cp=JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''));
        if ($case eq 'json') { reading('Geo.Test','gp_trip_checkpoint','{',$now); }
        elsif ($case eq 'version') { $cp->{version}='invalid'; }
        elsif ($case eq 'schema') { $cp->{state}{intents}=[{kind=>'garage_open'}]; }
        elsif ($case eq 'future') { $cp->{trip}{away_time}=$now+10000; }
        elsif ($case eq 'expired') { advance($cfg->{trip_resume_max_age}+1); }
        elsif ($case eq 'identity') { $attr{'Geo.Test'}{deviceId}='different'; }
        elsif ($case eq 'geometry') {
            my $g=JSON::PP::decode_json(GP_Read('Z.Home','gp_geometry',''));
            $g->{radius}=60; reading('Z.Home','gp_geometry',JSON::PP::encode_json($g),$now);
        } elsif ($case eq 'config') { $attr{'A.Door'}{command}='different'; }
        elsif ($case eq 'roommate') { advance(1); reading('rr_Test','state','home',$now); }
        elsif ($case eq 'phone') {
            advance(1); reading('p1','state','present',$now); reading('p1','presence','present',$now);
        }
        reading('Geo.Test','gp_trip_checkpoint',JSON::PP::encode_json($cp),$now) unless $case eq 'json';
        ($cfg,$s)=simulate_process_restart($c);
        ok(!$s->{trip},"$case checkpoint rejected");
        is($s->{resume}{status},'rejected',"$case rejection is explainable");
        is(scalar @commands,0,'rejection has no output');
    }
};

subtest 'pending arrival is not resumed and consumed checkpoint precedes synchronous command callbacks' => sub {
    my ($c,$cfg,$s)=saved_trip_fixture('remote'); advance(70);
    process($s,$cfg,'Home',1,'walking'); ok($s->{arrival},'old dwell timer pending');
    GP_Checkpoint($c,'Geo.Test',$cfg,$s);
    ($cfg,$s)=simulate_process_restart($c); ok(!$s->{arrival},'reboot never carries the old dwell timer');
    GP_TickState($s,$cfg,$now,$mono); GP_ConfirmArrival($s,$cfg,$now,$mono);
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono); is(scalar @commands,0,'time passing alone cannot open after reboot');
    advance(40); arrive($s,$cfg,'automotive');
    my $checked=0;
    $on_command=sub {
        return unless $_[0] =~ /^door /;
        is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none','checkpoint consumed before actuator callback');
        GP_ResetController($c,'resume'); $checked++;
    };
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono); $on_command=undef;
    is($checked,1,'callback reload really exercised');
    ok(!GP_State($c,'Geo.Test',0)->{trip},'callback reload cannot revive the just-consumed trip');
};

subtest 'mode changes revoke persisted trips and simulation never promotes them' => sub {
    my ($c,$cfg,$s)=saved_trip_fixture('remote');
    mode('Geo.Test','debug');
    is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none','explicit debug transition invalidates checkpoint');
    my $debug=GP_State($c,'Geo.Test',1); advance(40); process($debug,$cfg,'Work',1);
    GP_Checkpoint($c,'Geo.Test',$cfg,$debug);
    is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none','debug qualification cannot persist production permission');
    mode('Geo.Test','active'); ($cfg,$s)=simulate_process_restart($c);
    ok(!$s->{trip},'returning to active and rebooting creates no old permission');
};

subtest 'actuator state and measurement contracts preserve stale-feedback protection' => sub {
    my ($c,$cfg)=fixture(); actor_fresh(); advance(100);
    my ($door_rule)=grep {$_->{type} eq 'door_open'} @{$cfg->{rules}};
    my $intent={kind=>'door_open',params=>{%{$door_rule->{params}}}};
    is(GP_ActorView($intent,$now),'closed','held contact state remains valid across restart');
    $intent->{params}{positionSignalMode}='measurement';
    is(GP_ActorView($intent,$now),'unknown','measurement mode requires a post-start observation');
    actor_fresh(); advance(1); is(GP_ActorView($intent,$now-2),'closed','new measurement is accepted');
    $intent->{params}{positionSignalMode}='state'; $attr{contact}{disable}=1;
    is(GP_ActorView($intent,0),'unknown','disabled contact cannot authorize opening'); delete $attr{contact}{disable};
    $defs{contact}{STATE}='disconnected'; is(GP_ActorView($intent,0),'unknown','reported sensor outage blocks held state');
    $defs{contact}{STATE}='closed'; device('io','dummy'); $defs{io}{STATE}='disconnected'; $defs{contact}{IODev}=$defs{io};
    is(GP_ActorView($intent,0),'unknown','disconnected IO source blocks held state');
    $defs{contact}{IODev}='missing.IO';
    is(GP_ActorView($intent,0),'unknown','missing configured IO source blocks held state');
    delete $defs{contact}{IODev}; reading('contact','state','open',$now);
    is(GP_ActorView($intent,0),'open','known open position suppresses another pulse');
};

subtest 'resumed trips accept immediate new arrivals and still reject pre-start events' => sub {
    my ($c,$cfg,$s)=saved_trip_fixture('remote');
    ($cfg,$s)=simulate_process_restart($c);
    my $old=ev('Home',1,$now-1,'automotive');
    GP_Process($s,$cfg,$old,$now,$mono);
    ok(!$s->{arrival},'pre-start Home entry never resumes the old request');
    advance(1); process($s,$cfg,'Home',1,'automotive');
    ok($s->{arrival},'new Home entry can begin its normal wait one second after restart');
    is($s->{arrival}{wait},10,'no additional startup wait is added');
    complete_arrival($s,$cfg); GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is(scalar(grep {/^(?:door|garage) /} @commands),2,'fresh immediate return opens both requested actors');
};

subtest 'revocation reaches the checkpoint even when output is blocked' => sub {
    for my $cause (qw(conflict clock)) {
        my ($c,$cfg,$s)=saved_trip_fixture('remote');
        $c->{helper}{gp}{ready}=0;
        if ($cause eq 'conflict') {
            delete $s->{trip}; $s->{conflict}=1; GP_Trace($s,$now,'conflicting batch; actions quarantined');
        } else { $now+=100; GP_CheckClock($s,$cfg,$now,$mono); }
        GP_Publish($c,'Geo.Test',$cfg,$s);
        is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none',"$cause invalidates checkpoint while outputs blocked");
        ($cfg,$s)=simulate_process_restart($c); ok(!$s->{trip},'restart cannot revive revoked proof');
        ok(!defined($s->{resume_event_floor}),'unvalidated state retains the normal startup guard');
    }
};

subtest 'a new phone return confirms the resumed trip without a Home webhook' => sub {
    my ($c,$cfg,$s)=saved_trip_fixture('remote');
    ($cfg,$s)=simulate_process_restart($c); advance(2);
    my $samples=negative_samples(); $samples->{p1}{value}='present';
    my $e=phone_tick($s,$cfg,$samples);
    is($e->{kind},'phone_present','post-start observation is a real phone return');
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is(scalar(grep {/^(?:door|garage) /} @commands),2,'phone fallback uses the restored remote proof');
    is(JSON::PP::decode_json(GP_Read('Geo.Test','gp_trip_checkpoint',''))->{status},'none','phone return consumes checkpoint before output');
};

sub nonopening_fixture {
    my ($first)=@_;
    my ($c)=fixture();mode('GP','debug');device('lamp','dummy');
    gp_define('A.OutputLight','action GP switch_on');
    attribute('A.OutputLight','target','lamp');attribute('A.OutputLight','command','on');
    my $rule=$first eq 'switch_on' ? 'R.AOutputLight':'R.ZOutputLight';
    gp_define($rule,'rule GP');
    attribute($rule,'residents','Geo.Test');attribute($rule,'trigger','enter');
    attribute($rule,'locationGroup','Work');attribute($rule,'action','A.OutputLight');
    mode('GP','active');
    my $cfg=GP_Config($c,'Geo.Test',0);my $s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Work',1);
    return ($c,$cfg,$s);
}

subtest 'manual Home during the door callback revokes the remaining garage plan' => sub {
    my ($c,$cfg,$s)=pending_fixture('automotive');complete_arrival($s,$cfg);actor_fresh();
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open','garage_open'],'both openings are planned');
    my $revision=$s->{output_revision};
    $on_command=sub {
        return unless $_[0] eq 'door lock unlocked';
        reading('rr_Test','state','home',$now);
        local $defs{rr_Test}{CHANGED}=['home'];GeoPresence_Notify($c,$defs{rr_Test});
    };
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is_deeply(\@commands,['door lock unlocked'],'manual Home stops the copied garage plan');
    cmp_ok($s->{output_revision},'>',$revision,'revocation advances the output version even when already Home');
    ok(!$c->{helper}{gp}{actors}{garage},'cancelled garage plan creates no reservation');
    actor_event($c,'feedback','pulse_state','confirmed');GP_ActorFeedback($c,$now,$mono);
    is($s->{door_result},'confirmed','the already issued door request still receives feedback');
};

subtest 'ROOMMATE callbacks revoke extracted plans while actor feedback stays observable' => sub {
    my ($c,$cfg,$other_cfg)=shared_actor_fixture();my $s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Work',0);advance(90);actor_fresh();
    process($s,$cfg,'Home',1,'automotive');complete_arrival($s,$cfg);
    my $other=GP_State($c,'Geo.Other',0);$other->{desired_status}='home';
    reading('rr_Other','state','absent',$now);
    $on_command=sub {
        if ($_[0] eq 'door lock unlocked') {GP_Publish($c,'Geo.Other',$other_cfg,$other);}
        elsif ($_[0] eq 'rr_Other state home') {
            roommate_event($c,'rr_Test','home');
            actor_event($c,'feedback','pulse_state','confirmed');
        }
    };
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);$on_command=undef;
    is_deeply(\@commands,['door lock unlocked','rr_Other state home'],
        'manual Home inside another status command stops the extracted garage plan');
    ok(!$c->{helper}{gp}{actors}{garage},'revoked garage plan creates no actor reservation');
    GP_ActorFeedback($c,$now,$mono);
    is($s->{door_result},'confirmed','door completion is retained during the nested status command');
};

subtest 'every opening uses current clocks after a synchronous callback' => sub {
    for my $delay (89,90,91) {
        my ($c,$cfg,$s)=pending_fixture('automotive');complete_arrival($s,$cfg);actor_fresh();
        my ($old_wall,$old_mono)=($now,$mono);
        $on_command=sub {advance($delay) if $_[0] eq 'door lock unlocked'};
        GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$old_wall,$old_mono);
        is_deeply(\@commands,$delay<=90 ? ['door lock unlocked','garage on']:['door lock unlocked'],
            "delay $delay is checked against the remaining arrival budget");
    }
    my ($c,$cfg,$s)=pending_fixture('automotive');complete_arrival($s,$cfg);actor_fresh();
    my ($old_wall,$old_mono)=($now,$mono);advance(91);
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$old_wall,$old_mono);
    is_deeply(\@commands,[],'stale caller clocks cannot authorize even the first output');
};

subtest 'notification and switch callbacks use the same revocable output gate' => sub {
    for my $first (qw(notify switch_on)) {
        for my $reason (qw(manual expired)) {
            my ($c,$cfg,$s)=nonopening_fixture($first);
            is(scalar @{$s->{intents}},2,'two ordinary output plans');
            my $callback=sub {
                if ($reason eq 'expired') {advance(91);return;}
                local $defs{rr_Test}{CHANGED}=['home'];GeoPresence_Notify($c,$defs{rr_Test});
            };
            $on_message=$callback if $first eq 'notify';
            $on_command=$callback if $first eq 'switch_on';
            GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
            is(scalar(@messages)+scalar(@commands),1,"$first callback blocks the next output: $reason");
        }
    }
};

subtest 'small wall-clock corrections cannot extend a monotonic output deadline' => sub {
    my ($c,$cfg,$s)=nonopening_fixture('notify');advance(89);
    $on_message=sub {$mono+=2;$now-=2};
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is(scalar @messages,1,'first notification is still fresh');
    is_deeply(\@commands,[],'monotonic deadline rejects the second output');
    ok(!grep({$_->{reason} eq 'clock discontinuity; permissions revoked'} @{$s->{trace}}),
        'small correction stays below the discontinuity threshold');
};

subtest 'changed configuration cancels pending outputs without rebuilding it' => sub {
    for my $cold (0,1) {
        for my $event ('MODIFIED contact','ATTR contact event-on-change-reading state','DELETEATTR contact',
                'DEFINED contact','RENAMED contact contact.New') {
            my ($c,$cfg,$s)=nonopening_fixture('notify');
            $on_message=sub {
                GP_InvalidateDevices($c) if $cold;
                $event =~ /^RENAMED/ ? rename_device('contact','contact.New') : config_event($event);
            };
            my $build=\&GP_Catalog;my $calls=0;my $update=\&GP_UpdateAttrLists;my $widgets=0;
            {
                no warnings 'redefine';local *GP_Catalog=sub {$calls++;return $build->(@_)};
                local *GP_UpdateAttrLists=sub {$widgets++;return $update->(@_);};
                GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
            }
            is(scalar @messages,1,"first output precedes $event (cold=$cold)");
            is_deeply(\@commands,[],'obsolete configuration cannot authorize the switch');
            is($calls,0,'discarding obsolete plans never rebuilds or reads the catalogue');
            is($widgets,0,'dependent dummy events revoke plans without rebuilding widget choices');
            ok(!$c->{helper}{gp_config},'rebuilding remains deferred until a new consumer');
        }
    }
};

subtest 'unrelated configuration changes retain another resident output batch' => sub {
    my ($c,$cfg,$s)=nonopening_fixture('notify');
    $on_message=sub {
        device('rr_New','ROOMMATE');$attr{rr_New}{rr_locationUnderway}='underway';
        gp_define('Geo.New','resident GP rr_New');
        attribute('Geo.New','sourceMode','phone_only');attribute('Geo.New','phoneProxies','p1');
    };
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is(scalar @messages,1,'first notification executes');
    is_deeply(\@commands,['lamp on'],'unrelated setup cannot cancel the still-authorized switch');
};

subtest 'expiration during subscription leaves no unissued actor reservation' => sub {
    my ($c,$cfg,$s)=pending_fixture('automotive');complete_arrival($s,$cfg);actor_fresh();
    my $subscribe=\&setNotifyDev;my $delayed=0;
    {
        no warnings 'redefine';
        local *setNotifyDev=sub {
            advance(91) if !$delayed++;
            return $subscribe->(@_);
        };
        GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    }
    is_deeply(\@commands,[],'final gate checks clocks after subscription');
    is_deeply($c->{helper}{gp}{actors},{},'undispatched reservation is removed');
};

subtest 'display aliases cannot revoke a valid opening sequence' => sub {
    for my $name (qw(Geo.Test rr_Test door)) {
        for my $operation (qw(set del)) {
            my ($c,$cfg,$s)=pending_fixture('automotive');complete_arrival($s,$cfg);actor_fresh();
            $attr{$name}{alias}='Previous name';my $revision=$s->{output_revision};
            my $catalog=$c->{helper}{gp_config};
            $on_command=sub {
                return unless $_[0] eq 'door lock unlocked';
                $operation eq 'set' ? attribute($name,'alias','New name') : delete_attributes($name,'alias');
            };
            GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
            is_deeply(\@commands,['door lock unlocked','garage on'],"$operation $name alias keeps the garage authorized");
            is($s->{output_revision},$revision,'display edit keeps the output version');
            is($c->{helper}{gp_config},$catalog,'live display alias keeps the prepared configuration') if $name ne 'rr_Test';
            is(GP_Config($c,'Geo.Test')->{label},$operation eq 'set'?'New name':'rr_Test',
                'subsequent configuration reads refresh the ROOMMATE label') if $name eq 'rr_Test';
        }
    }
};

subtest 'a clock correction during the arrival wait cannot extend output freshness' => sub {
    for my $delay (90,95) {
        my ($c,$cfg,$s)=pending_fixture('unknown');my $receipt=$mono;
        advance(50);$now-=10;GP_CheckClock($s,$cfg,$now,$mono);advance(10);
        complete_arrival($s,$cfg);actor_fresh();
        is($s->{intents}[0]{expires_mono},$receipt+150,'deadline remains anchored before the clock correction');
        $on_command=sub {advance($delay) if $_[0] eq 'door lock unlocked'};
        GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
        is_deeply(\@commands,$delay==90?['door lock unlocked','garage on']:['door lock unlocked'],
            "remaining $delay seconds are measured from the original receipt");
    }
    my ($c,$cfg,$s)=pending_fixture('unknown');
    advance(50);$now-=10;GP_CheckClock($s,$cfg,$now,$mono);advance(105);
    GP_ConfirmArrival($s,$cfg,$now,$mono);
    ok(!$s->{arrival},'a delayed confirmation cannot revive the expired budget');
    is_deeply($s->{intents},[],'expired confirmation creates no output plans');
};

subtest 'receipt clocks survive the webhook reorder queue' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Work',0);advance(90);
    my $receipt=$mono;
    is((http($c,form($cfg,'Home',1,$now)))[0],200,'Home webhook accepted');
    advance(3);$now-=1;GeoPresence_Timer($c);
    is($s->{arrival}{start_mono},$receipt,'queued observation keeps its original monotonic reception time');
    complete_arrival($s,$cfg);
    is($s->{intents}[0]{expires_mono},$receipt+150,'reordering does not shift the action deadline');
};

subtest 'controller bulk deletions obey the active configuration guard' => sub {
    for my $pattern ('action_max_ag.',undef) {
        my ($c,$cfg,$s)=pending_fixture('unknown',action_max_age=>180);complete_arrival($s,$cfg);actor_fresh();
        my $error;
        $on_command=sub {$error=delete_attributes('GP',$pattern) if $_[0] eq 'door lock unlocked'};
        GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
        like($error//'',qr/Controller configuration requires/,'bulk deletion is rejected before FHEM commits it');
        is($attr{GP}{action_max_age},180,'rejected deletion retains the configured freshness limit');
        is_deeply(\@commands,['door lock unlocked','garage on'],'rejected change leaves the original sequence valid');
    }
};

subtest 'committed controller deletions revoke every affected output even with cold caches' => sub {
    for my $cold (0,1) {
        for my $pattern ('action_max_ag.',undef) {
            my ($c,$cfg,$s)=pending_fixture('unknown',action_max_age=>180);complete_arrival($s,$cfg);actor_fresh();
            my $revision=$s->{output_revision};
            $on_command=sub {
                return unless $_[0] eq 'door lock unlocked';
                GP_InvalidateDevices($c) if $cold;
                delete $attr{GP}{action_max_age};
                config_event('DELETEATTR GP'.(defined($pattern)?' '.$pattern:''));
            };
            my $catalog=\&GP_Catalog;my $builds=0;
            {
                no warnings 'redefine';local *GP_Catalog=sub {$builds++;return $catalog->(@_)};
                GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
            }
            is_deeply(\@commands,['door lock unlocked'],'committed controller change suppresses the garage');
            cmp_ok($s->{output_revision},'>',$revision,'controller is a dependency of each resident');
            is($builds,0,'revocation needs no configuration rebuild');
        }
    }
};

subtest 'deletion patterns validate and reset their combined change once' => sub {
    my ($c)=fixture();mode('GP','debug');
    attribute('GP','action_max_age',200);attribute('GP','reorder_window',120);
    like(delete_attributes('GP','action_max_ag.'),qr/smaller than action_max_age/,
        'pattern cannot restore an age incompatible with the remaining window');
    is($attr{GP}{action_max_age},200,'rejected deletion retains the old value');
    my $epoch=$c->{helper}{gp}{epoch};
    is(delete_attributes('GP','action_max_ag.|reorder_windo.'),undef,'combined default pair is valid');
    is($c->{helper}{gp}{epoch},$epoch+1,'combined deletion resets the controller once');
    my $cfg=GP_Config($c,'Geo.Test');
    is_deeply([@$cfg{qw(action_max_age reorder_window)}],[90,2],'both defaults are visible together');
    mode('GP','active');
    my $s=GP_State($c,'Geo.Test',0);my $revision=$s->{output_revision};
    $attr{GP}{debugLog}=1;$attr{GP}{logFile}='/tmp/unused-geopresence-review.log';
    my $catalog=$c->{helper}{gp_config};
    is(delete_attributes('GP','debugLo.|logFil.'),undef,'diagnostic-only pattern remains allowed while active');
    is($s->{output_revision},$revision,'diagnostic pattern does not revoke outputs');
    is($c->{helper}{gp_config},$catalog,'diagnostic pattern keeps the prepared configuration');
};

subtest 'ROOMMATE alias deletion patterns preserve the remaining opening' => sub {
    for my $pattern ('^alias$','a.ias','[a]lias','^(alias|room)$','(?x) ^ alias $') {
        for my $cold (0,1) {
            my ($c,$cfg,$s)=pending_fixture('automotive');complete_arrival($s,$cfg);actor_fresh();
            $attr{rr_Test}{alias}='Previous name';my $revision=$s->{output_revision};
            $on_command=sub {
                return unless $_[0] eq 'door lock unlocked';
                GP_InvalidateDevices($c) if $cold;
                is(delete_attributes('rr_Test',$pattern),undef,'ROOMMATE display deletion accepted');
            };
            GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
            is_deeply(\@commands,['door lock unlocked','garage on'],"$pattern preserves the garage, cold=$cold");
            is($s->{output_revision},$revision,'display pattern keeps the output version');
            is(GP_Config($c,'Geo.Test')->{label},'rr_Test','subsequent configuration uses the remaining ROOMMATE name');
        }
    }
    my ($c,$cfg,$s)=pending_fixture('automotive');complete_arrival($s,$cfg);actor_fresh();
    $attr{rr_Test}{alias}='Previous name';
    $on_command=sub {delete_attributes('rr_Test','^(alias|rr_locationUnderway)$') if $_[0] eq 'door lock unlocked'};
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
    is_deeply(\@commands,['door lock unlocked'],'a pattern removing a functional ROOMMATE attribute still revokes the garage');
};

subtest 'deleting obsolete attributes refreshes cached validation without compiling in callbacks' => sub {
    for my $case (['R.Work','^(role|condition)$',[qw(role condition)],qr/unsupported rule attribute/],
                  ['R.Work','(?x) ^ (role | condition) $',[qw(role condition)],qr/unsupported rule attribute/],
                  ['GP','^(mode|operatingMode)$',[qw(mode operatingMode)],qr/remove obsolete attribute/],
                  ['Geo.Test','^(mode|operatingMode)$',[qw(mode operatingMode)],qr/remove obsolete attribute/]) {
        my ($name,$pattern,$keys,$message)=@$case;
        my ($c)=fixture();mode('GP','debug');
        $attr{$name}{$_}='obsolete' for @$keys;
        GP_InvalidateConfig($c);
        like(join('; ',GP_Validate($c,'Geo.Test')), $message, 'obsolete attributes are cached as invalid');
        my $catalog=\&GP_Catalog;my $builds=0;
        {
            no warnings 'redefine';local *GP_Catalog=sub {$builds++;return $catalog->(@_)};
            is(delete_attributes($name,$pattern),undef,"cleanup $pattern accepted");
        }
        is($builds,0,'cleanup callbacks do not compile a catalogue');
        ok(!$c->{helper}{gp_config},'the obsolete validation cache is discarded');
        is_deeply([GP_Validate($c,'Geo.Test')],[],'subsequent validation sees the cleaned configuration');
        is(GeoPresence_Set($c,'GP','mode','active'),undef,'the cleaned configuration can be activated');
    }
};

subtest 'distinct observation times need no pairwise batch conflict comparisons' => sub {
    my ($c,$cfg)=fixture();advance(100);my $latest=$now;
    for my $age (reverse 0..63) {
        is((http($c,form($cfg,'Home',1,$latest-$age)))[0],200,'fresh distinct observation accepted');
    }
    my $compare=\&GP_Contradiction;my $comparisons=0;
    advance(2);
    {
        no warnings 'redefine';
        local *GP_Contradiction=sub {$comparisons++;return $compare->(@_)};
        GeoPresence_Timer($c);
    }
    cmp_ok($comparisons,'<=',64,'only the ordinary checks against the preceding location remain');
    is(scalar @{$c->{helper}{gp}{queue}},0,'the entire due batch is processed');
    my $s=GP_State($c,'Geo.Test',0);
    is($s->{last_observed},$latest,'the newest observation is processed');
    ok(!$s->{conflict},'distinct times do not quarantine the batch');
};

subtest 'a continuous event stream cannot extend the first receipt window' => sub {
    my ($c,$cfg)=fixture();advance(40);
    for my $step (0..5) {
        is((http($c,form($cfg,'Work',1,$now)))[0],200,"stream observation $step accepted");
        GeoPresence_Timer($c);
        is(scalar @{$c->{helper}{gp}{queue}},($step+1)%3,"fixed window at stream step $step");
        is(scalar @messages,$step<2?0:1,'ordinary visit is executed once when the first window closes');
        advance(1) if $step<5;
    }
    is(GP_State($c,'Geo.Test',0)->{last_observed},$now,'the last window includes its newest received observation');
};

subtest 'the due batch includes newer counterevidence before confirming arrival' => sub {
    for my $exit (qw(Home Drive Outer Work)) {
        my ($c,$cfg,$s)=pending_fixture('automotive');
        advance(8);
        is((http($c,form($cfg,'Home',1,$now)))[0],200,'first observation starts a two-second window');
        advance(1);
        is((http($c,form($cfg,$exit,$exit eq 'Work'?1:0,$now)))[0],200,'newer counterevidence accepted');
        advance(1);GeoPresence_Timer($c);
        is(scalar @{$c->{helper}{gp}{queue}},0,"$exit is processed at the first deadline");
        ok(!$s->{arrival},"$exit cancels the pending arrival in that batch");
        is(scalar(grep {/^(door|garage) /} @commands),0,"$exit prevents physical output");
        ok(!$c->{helper}{gp}{actors}{door} && !$c->{helper}{gp}{actors}{garage},'no opening reservation is created');
    }
};

subtest 'productive and debug batches keep independent fixed windows' => sub {
    my ($c,$cfg)=fixture();advance(40);
    is((http($c,form($cfg,'Work',1,$now)))[0],200,'productive observation accepted');
    advance(1);
    is((http($c,form($cfg,'Work',1,$now),1))[0],200,'debug observation accepted');
    advance(1);
    is((http($c,form($cfg,'Work',1,$now),1))[0],200,'newer debug observation accepted');
    GeoPresence_Timer($c);
    is(scalar(grep {!$_->{debug}} @{$c->{helper}{gp}{queue}}),0,'productive window is due');
    is(scalar(grep {$_->{debug}} @{$c->{helper}{gp}{queue}}),2,'debug window has its own later deadline');
    is(scalar @messages,1,'only the productive visit sends a message');
    advance(1);GeoPresence_Timer($c);
    is(scalar @{$c->{helper}{gp}{queue}},0,'debug window closes despite its later observation');
    is(scalar @messages,1,'debug processing creates no real notification');
};

subtest 'an older entry in the same pending arrival can supply missing motion' => sub {
    for my $case ([first=>'walking'],[later=>'walking'],[first=>'automotive'],[later=>'automotive']) {
        my ($which,$motion)=@$case;
        my ($c,$cfg,$s)=pending_fixture('unknown');
        my $first={%{$s->{arrival}{event}}};my $start=$s->{arrival}{start_mono};
        advance(5);process($s,$cfg,'Home',1);
        my $source=$which eq 'first'?$first:{%{$s->{arrival}{latest_home}}};
        advance(5);process($s,$cfg,'Home',1);
        my $latest={%{$s->{arrival}{latest_home}}};my $position=$s->{position_time};
        my $visits=JSON::PP->new->canonical->encode([@$s{qw(zones members zone_visits group_visits)}]);
        advance(1);
        GP_Process($s,$cfg,{%$source,motion=>$motion,received=>$now,received_mono=>$mono},$now,$mono);
        is($s->{arrival}{motion},$motion,"$which entry fills $motion after newer empty entries");
        is($s->{arrival}{vehicle_eligible},$motion eq 'automotive'?1:0,'vehicle permission follows the supplied motion');
        is($s->{motion_time},$source->{time},'motion keeps its original observation time');
        is($s->{position_time},$position,'supplement does not rewind position');
        is_deeply($s->{arrival}{latest_home},$latest,'supplement retains the newest Home evidence');
        is($s->{arrival}{started},$first->{received},'arrival retains the first receipt');
        is($s->{arrival}{start_mono},$start,'monotonic receipt anchor is unchanged');
        is($s->{arrival}{due_mono},$start+($motion eq 'walking'?60:10),'motion deadline is still based on the first receipt');
        is(JSON::PP->new->canonical->encode([@$s{qw(zones members zone_visits group_visits)}]),$visits,
            'supplement replays no membership or visit changes');
        is_deeply($s->{intents},[],'supplement plans no additional actions');
        complete_arrival($s,$cfg);actor_fresh();GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
        is_deeply(\@commands,$motion eq 'walking'?['door lock unlocked']:['door lock unlocked','garage on'],
            'confirmed arrival executes only the permitted actors');
        GP_Process($s,$cfg,{%$source,motion=>$motion,received=>$now,received_mono=>$mono},$now,$mono);
        ok(!$s->{arrival} && !$s->{trip},'completed arrival is not reopened by its supplement');
    }
};

subtest 'HTTP motion supplement survives the geometry filter after newer Home entries' => sub {
    for my $phone (0,1) {
        my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
        advance(40);http($c,form($cfg,'Work',0,$now));advance(3);GeoPresence_Timer($c);
        advance(90);my $time=$now;my $original=form($cfg,'Home',1,$time);
        http($c,$original);advance(3);GeoPresence_Timer($c);
        my $first={%{$s->{arrival}{event}}};my $start=$s->{arrival}{start_mono};
        advance(2);my $latest=$now;http($c,form($cfg,'Home',1,$latest));advance(3);GeoPresence_Timer($c);
        advance(1);http($c,$original.'&motion=walking');
        if ($phone) {reading('p1','state','present',$now);reading('p1','presence','present',$now);}
        actor_fresh();advance($phone?5:3);GeoPresence_Timer($c);
        is($s->{motion},'walking','older HTTP duplicate supplies walking');
        is($s->{motion_time},$time,'HTTP receipt cannot refresh motion age');
        if (!$phone) {
            is($s->{arrival}{event}{received},$first->{received},'HTTP path keeps first wall-clock receipt');
            is($s->{arrival}{event}{received_mono},$first->{received_mono},'HTTP path keeps first monotonic receipt');
            is($s->{arrival}{latest_home}{time},$latest,'newest Home entry survives the old duplicate');
            is($s->{arrival}{due_mono},$start+60,'HTTP supplement does not restart the wait');
            advance($s->{arrival}{due_mono}-$mono);actor_fresh();GeoPresence_Timer($c);
        }
        is_deeply([grep {/^(?:door|garage) /} @commands],['door lock unlocked'],
            $phone?'walking veto is applied before queued phone confirmation':'timer confirmation honors the late walking veto');
    }
};

subtest 'the current approach retains its motion origin on entering Home' => sub {
    for my $gap (0,5) {
        for my $phone (0,1) {
            my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
            advance(40);http($c,form($cfg,'Work',0,$now));advance(3);GeoPresence_Timer($c);
            advance(90);my $time=$now;my $approach=form($cfg,'Drive',1,$time);
            http($c,$approach);advance(3);GeoPresence_Timer($c);
            ok(!$s->{arrival} && $s->{phase} eq 'returning','approach starts no Home wait');
            advance(2);http($c,form($cfg,'Home',1,$time+$gap));advance(3);GeoPresence_Timer($c);
            my $first={%{$s->{arrival}{event}}};my $start=$s->{arrival}{start_mono};
            ok($s->{arrival}{vehicle_eligible},'remote trip initially permits the garage');
            my $position=$s->{position_time};
            advance(1);http($c,$approach.'&motion=walking');
            if ($phone) {reading('p1','state','present',$now);reading('p1','presence','present',$now);}
            actor_fresh();advance($phone?5:3);GeoPresence_Timer($c);
            is($s->{motion},'walking',"approach supplement survives Home; gap=$gap phone=$phone");
            is($s->{motion_time},$time,'walking retains the approach observation time');
            if (!$phone) {
                ok(!$s->{arrival}{vehicle_eligible},'walking revokes the remote garage fallback');
                is_deeply($s->{arrival}{event},$first,'Home remains the original arrival evidence');
                is($s->{arrival}{start_mono},$start,'Home receipt still anchors the wait');
                is($s->{arrival}{due_mono},$start+60,'approach receipt does not move the Home deadline');
                is($s->{position_time},$position,'approach supplement does not rewind position');
                advance($s->{arrival}{due_mono}-$mono);actor_fresh();GeoPresence_Timer($c);
            }
            is_deeply([grep {/^(?:door|garage) /} @commands],['door lock unlocked'],
                'timer or phone confirmation opens only the door');
        }
    }
};

subtest 'an early approach cannot requalify or consume its pending Home arrival' => sub {
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
    advance(40);process($s,$cfg,'Work',0);advance(50);
    my $approach=ev('Drive',1,$now);GP_Process($s,$cfg,$approach,$now,$mono);
    advance(20);process($s,$cfg,'Home',1);my $home={%{$s->{arrival}{event}}};
    advance(1);GP_Process($s,$cfg,{%$approach,motion=>'walking',received=>$now,received_mono=>$mono},$now,$mono);
    ok($s->{arrival} && $s->{trip}{armed},'valid Home wait remains pending despite the earlier approach time');
    is($s->{arrival}{motion},'walking','pre-minimum-away approach supplies walking to the qualified Home arrival');
    is_deeply($s->{arrival}{event},$home,'approach cannot replace the qualifying Home event');
    is_deeply($s->{intents},[],'supplement cannot trigger immediate output');
    complete_arrival($s,$cfg);actor_fresh();GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
    is_deeply(\@commands,['door lock unlocked'],'qualified Home arrival still opens only the door');
};

subtest 'an interrupted or superseded approach cannot donate motion to Home' => sub {
    for my $boundary (qw(Home Drive Outer remote phone timeout newer_approach)) {
        my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
        advance(40);process($s,$cfg,'Work',0);advance(90);
        my $approach=ev('Drive',1,$now);GP_Process($s,$cfg,$approach,$now,$mono);
        advance(1);
        if ($boundary eq 'phone') {
            GP_Process($s,$cfg,{kind=>'phone_absent',generation=>$s->{generation},time=>$now,received=>$now,
                negative_generation=>$s->{phone}{negative_generation}//0,negative_wall=>$now,negative_since=>$mono,
                qualified_at=>$now,qualified_mono=>$mono},$now,$mono);
            ok(!$s->{approach} && $s->{phase} eq 'away','qualified phone absence ends the approach before Home');
        } elsif ($boundary eq 'timeout') {
            $cfg->{approach_timeout}=5;advance(5);GP_TickState($s,$cfg,$now,$mono);
        } elsif ($boundary eq 'newer_approach') {
            process($s,$cfg,'Drive',1);
        } else {
            process($s,$cfg,$boundary eq 'remote'?'Work':$boundary,0);
            advance(61) if $boundary eq 'Outer' || $boundary eq 'Drive' || $boundary eq 'remote';
        }
        advance(1);process($s,$cfg,'Home',1);
        ok($s->{arrival},"$boundary is followed by a separate valid Home arrival");
        advance(1);GP_Process($s,$cfg,{%$approach,motion=>'walking',received=>$now,received_mono=>$mono},$now,$mono);
        is($s->{arrival}{motion},'unknown',"$boundary prevents the old approach from supplying motion");
        ok($s->{arrival}{vehicle_eligible},'unrelated old motion cannot change the garage decision');
    }
};

subtest 'delayed exits interrupt the approach origin without rewinding position' => sub {
    for my $zone (qw(Home Drive Outer)) {
        for my $after_home (0,1) {
            my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
            $cfg->{zones}{'Z.Checkpoint'}{lat}=0.0009;$cfg->{zones}{'Z.Checkpoint'}{radius}=20;
            advance(40);process($s,$cfg,'Drive',0);advance(90);
            is($s->{trip}{scope},'local','garage needs a separate vehicle proof');
            my $time=$now;my $approach=ev('Drive',1,$time);
            GP_Process($s,$cfg,$approach,$now,$mono);
            advance(20);process($s,$cfg,'Checkpoint',1);
            if ($after_home) {
                advance(10);process($s,$cfg,'Home',1);
                advance(5);process($s,$cfg,'Home',1);
            } else {advance(3);}
            my $pending=$s->{arrival};
            my $position=$s->{position_time};
            my $visits=JSON::PP->new->canonical->encode([@$s{qw(zones members zone_visits group_visits)}]);
            my $exit=ev($zone,0,$time+10);$exit->{received}=$now;$exit->{received_mono}=$mono;
            GP_Process($s,$cfg,$exit,$now,$mono);
            is($s->{position_time},$position,'late exit does not rewind the newer position');
            is(JSON::PP->new->canonical->encode([@$s{qw(zones members zone_visits group_visits)}]),$visits,
                'late exit does not replay memberships or visits');
            ok(!$s->{approach},"$zone exit removes any pre-Home approach origin");
            if ($after_home) {
                is_deeply($s->{arrival}{event},$pending->{event},'exit before Home preserves the qualifying Home event');
                is($s->{arrival}{start_mono},$pending->{start_mono},'exit before Home preserves the original wait anchor');
                is($s->{arrival}{due_mono},$pending->{due_mono},'exit before Home does not postpone the deadline');
                is_deeply($s->{arrival}{latest_home},$pending->{latest_home},'newest Home remains available for later exits');
            } else {
                advance(7);process($s,$cfg,'Home',1);
            }
            advance(10);GP_Process($s,$cfg,{%$approach,motion=>'automotive',received=>$now,received_mono=>$mono},$now,$mono);
            ok(!$s->{arrival}{vehicle_eligible},"$zone exit rejects the interrupted automotive origin; after_home=$after_home");
            is($s->{arrival}{motion},'unknown','old supplement does not change the pending motion');
            if ($after_home) {
                my $exit=ev($zone,0,$time+32);$exit->{received}=$now;$exit->{received_mono}=$mono;
                GP_Process($s,$cfg,$exit,$now,$mono);
                is($s->{arrival}{event}{key},$pending->{latest_home}{key},'a subsequent exit during Home restarts from the newest entry');
                is($s->{arrival}{start_mono},$pending->{latest_home}{received_mono},'new wait uses that entry\'s original receipt');
            }
            complete_arrival($s,$cfg);actor_fresh();GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
            is_deeply(\@commands,['door lock unlocked'],'valid Home arrival opens only the door');
        }
    }
};

subtest 'HTTP filter retains an unchanged delayed exit before Home' => sub {
    for my $case (qw(interrupted earlier_exit changed_geometry new_approach)) {
        my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
        advance(40);http($c,form($cfg,'Checkpoint',1,$now,latitude=>0.0009,radius=>20));advance(3);GeoPresence_Timer($c);
        $cfg=GP_Config($c,'Geo.Test');
        http($c,form($cfg,'Drive',0,$now));advance(3);GeoPresence_Timer($c);advance(90);
        my $time=$now;my $approach=form($cfg,'Drive',1,$time);
        http($c,$approach);advance(3);GeoPresence_Timer($c);
        advance(17);http($c,form($cfg,'Checkpoint',1,$now));advance(3);GeoPresence_Timer($c);
        my $position=$s->{position_time};
        http($c,form($cfg,'Drive',0,$time+($case eq 'earlier_exit'?-1:10),
            radius=>$case eq 'changed_geometry'?251:250));advance(3);GeoPresence_Timer($c);
        is($s->{position_time},$position,'HTTP late exit retains the newer position');
        is(GP_Config($c,'Geo.Test')->{zones}{'Z.Drive'}{radius},250,'late exit cannot restore different geometry');
        if ($case eq 'new_approach') {
            advance(1);$approach=form($cfg,'Drive',1,$now);
            http($c,$approach);advance(3);GeoPresence_Timer($c);
        }
        advance(4);http($c,form($cfg,'Home',1,$now));advance(3);GeoPresence_Timer($c);
        my $start=$s->{arrival}{start_mono};
        advance(1);http($c,$approach.'&motion=automotive');advance(3);GeoPresence_Timer($c);
        is($s->{arrival}{vehicle_eligible},$case eq 'interrupted'?0:1,"HTTP supplement respects $case");
        is($s->{arrival}{start_mono},$start,'supplement does not restart the Home wait');
        advance($s->{arrival}{due_mono}-$mono);actor_fresh();GeoPresence_Timer($c);
        is_deeply([grep {/^(?:door|garage) /} @commands],$case eq 'interrupted'?['door lock unlocked']:['door lock unlocked','garage on'],
            'actual actor commands follow the valid motion origin');
    }
};

subtest 'late exits revoke cached approach motion and retain newer Home motion' => sub {
    for my $home_motion (qw(unknown automotive walking)) {
        my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
        $cfg->{arrival_wait_automotive}=60;
        advance(40);process($s,$cfg,'Drive',0);advance(90);
        my $time=$now;process($s,$cfg,'Drive',1,'automotive');
        advance(35);process($s,$cfg,'Home',1,$home_motion);my $first=$s->{arrival};
        ok($s->{arrival}{vehicle_eligible},'approach automotive initially qualifies the garage');
        advance(3);my $exit=ev('Drive',0,$time+10);$exit->{received}=$now;$exit->{received_mono}=$mono;
        GP_Process($s,$cfg,$exit,$now,$mono);
        is($s->{arrival}{vehicle_eligible},$home_motion eq 'automotive'?1:0,'only newer Home automotive can retain vehicle permission');
        is($s->{arrival}{motion},$home_motion,'motion before the exit is cleared and newer motion is retained');
        is($s->{arrival}{start_mono},$first->{start_mono},'reevaluation keeps the original Home receipt');
        complete_arrival($s,$cfg);actor_fresh();GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
        is_deeply(\@commands,$home_motion eq 'automotive'?['door lock unlocked','garage on']:['door lock unlocked'],
            'commands use only motion after the interruption');
    }
};

subtest 'a pre-Home exit preserves the latched walking veto after its TTL' => sub {
    for my $zone (qw(Home Drive Outer)) {
        for my $phone (0,1) {
            my ($c)=fixture();mode('GP','debug');attribute('GP','motion_max_age',20);mode('GP','active');
            GeoPresence_Timer($c);
            my $cfg=GP_Config($c,'Geo.Test');my $s=GP_State($c,'Geo.Test',0);
            is($cfg->{motion_max_age},20,'short motion TTL is accepted through the attribute callback');
            advance(40);is((http($c,form($cfg,'Work',0,$now)))[0],200,'remote departure accepted');
            advance(3);GeoPresence_Timer($c);advance(90);
            my $time=$now;http($c,form($cfg,'Drive',1,$time));advance(3);GeoPresence_Timer($c);
            advance(7);http($c,form($cfg,'Home',1,$now,motion=>'walking'));advance(3);GeoPresence_Timer($c);
            my $first={%{$s->{arrival}}};
            ok(!$first->{vehicle_eligible},'fresh Home walking initially vetoes the remote fallback');
            advance(27);http($c,form($cfg,$zone,0,$time+5));advance(3);GeoPresence_Timer($c);
            cmp_ok($now-$s->{motion_time},'>',$cfg->{motion_max_age},'Home walking has aged beyond its TTL');
            ok(!$s->{arrival}{vehicle_eligible},"$zone exit cannot age the walking veto into permission; phone=$phone");
            is($s->{arrival}{motion},'walking','unaffected accepted motion stays latched');
            is($s->{arrival}{due_mono},$first->{due_mono},'pre-Home interruption leaves the original deadline');
            is_deeply($s->{arrival}{event},$first->{event},'original Home event and receipt remain intact');
            is($s->{arrival}{origin_time},$first->{event}{time},'older approach origins are still revoked');
            if ($phone) {
                advance(1);
                reading('p1','state','present',$now);reading('p1','presence','present',$now);
                advance(5);
            } else {advance($s->{arrival}{due_mono}-$mono);}
            actor_fresh();GeoPresence_Timer($c);
            is_deeply([grep {/^(?:door|garage) /} @commands],['door lock unlocked'],
                'timer or phone confirms the door without a garage command');
        }
    }
};

subtest 'only revoked motion is reassessed at its original evaluation time' => sub {
    for my $case ([walking=>'unknown',1,'unknown'],[automotive=>'walking',0,'walking'],
                  [automotive=>'running',0,'running'],[automotive=>'cycling',0,'cycling'],
                  [unknown=>'automotive',1,'automotive'],[unknown=>'walking',1,'automotive','automotive']) {
        my ($approach_motion,$home_motion,$eligible,$retained,$new_motion)=@$case;
        my ($c)=fixture();mode('GP','debug');attribute('GP','motion_max_age',20);
        attribute('GP','arrival_wait_'.$_,60) for qw(running cycling automotive);
        mode('GP','active');GeoPresence_Timer($c);
        my $cfg=GP_Config($c,'Geo.Test');my $s=GP_State($c,'Geo.Test',0);
        advance(40);process($s,$cfg,'Work',0);advance(90);my $time=$now;
        process($s,$cfg,'Drive',1,$approach_motion);advance(10);process($s,$cfg,'Home',1,$home_motion);
        my $first={%{$s->{arrival}}};advance(33);
        my $exit=ev('Drive',0,$time+5);$exit->{received}=$now;$exit->{received_mono}=$mono;
        GP_Process($s,$cfg,$exit,$now,$mono);
        if ($new_motion) {
            ok(!$s->{arrival}{vehicle_eligible},'walking veto persists until new vehicle evidence');
            advance(1);process($s,$cfg,'Home',1,$new_motion);
        }
        is($s->{arrival}{vehicle_eligible},$eligible,"$approach_motion before exit, $home_motion after exit: correct vehicle decision");
        is($s->{arrival}{motion},$retained,'revoked motion is removed and unaffected motion retains its accepted validity');
        is($s->{arrival}{start_mono},$first->{start_mono},'reassessment retains the Home receipt');
        is($s->{arrival}{due_mono},$first->{due_mono},'unchanged configured wait retains the original deadline');
        complete_arrival($s,$cfg);actor_fresh();GP_Dispatch($c,'Geo.Test',$cfg,$s,0);
        is_deeply(\@commands,$eligible?['door lock unlocked','garage on']:['door lock unlocked'],
            'output follows the surviving evidence rather than elapsed TTL alone');
    }
};

subtest 'supplements cannot replace newer motion or enter another arrival' => sub {
    for my $newer (qw(walking automotive)) {
        my ($c,$cfg,$s)=pending_fixture('unknown');my $old={%{$s->{arrival}{event}}};
        advance(5);process($s,$cfg,'Home',1,$newer);my $time=$s->{motion_time};
        advance(1);GP_Process($s,$cfg,{%$old,motion=>$newer eq 'walking'?'automotive':'walking',
            received=>$now,received_mono=>$mono},$now,$mono);
        is($s->{arrival}{motion},$newer,'newer useful motion is retained');
        is($s->{motion_time},$time,'older supplement cannot replace the newer timestamp');
    }
    my ($c,$cfg,$s)=pending_fixture('unknown');my $old={%{$s->{arrival}{event}}};
    advance(5);process($s,$cfg,'Home',0);advance(1);process($s,$cfg,'Home',1);
    my $current={%{$s->{arrival}{event}}};
    advance(1);GP_Process($s,$cfg,{%$old,motion=>'walking',received=>$now,received_mono=>$mono},$now,$mono);
    is($s->{arrival}{motion},'unknown','a cancelled arrival cannot provide motion to its successor');
    is_deeply($s->{arrival}{event},$current,'successor keeps its own original evidence');
};

subtest 'an unaccepted origin or changed old geometry cannot supply motion' => sub {
    for my $case (qw(unseen geometry)) {
        my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
        advance(40);http($c,form($cfg,'Work',0,$now));advance(3);GeoPresence_Timer($c);
        advance(90);my $time=$now;http($c,form($cfg,'Home',1,$time));advance(3);GeoPresence_Timer($c);
        advance(2);http($c,form($cfg,'Home',1,$now));advance(3);GeoPresence_Timer($c);
        my $body=form($cfg,'Home',1,$time-($case eq 'unseen'?1:0),motion=>'walking',
            radius=>$case eq 'geometry'?55:50);
        is((http($c,$body))[0],200,'late observation is accepted by the HTTP adapter');
        advance(3);GeoPresence_Timer($c);
        is($s->{arrival}{motion},'unknown',"$case observation cannot supplement the current arrival");
        ok($s->{arrival}{vehicle_eligible},'unrelated evidence does not rewrite the cached vehicle decision');
        is(GP_Config($c,'Geo.Test')->{zones}{'Z.Home'}{radius},50,'old geometry is not restored');
    }
};

subtest 'a late exit still uses the newest Home entry after motion enrichment' => sub {
    my ($c,$cfg,$s)=pending_fixture('unknown');my $old={%{$s->{arrival}{event}}};
    advance(5);process($s,$cfg,'Home',1);my $latest={%{$s->{arrival}{latest_home}}};
    advance(3);GP_Process($s,$cfg,{%$old,motion=>'walking',received=>$now,received_mono=>$mono},$now,$mono);
    my $exit=ev('Home',0,$old->{time}+3);$exit->{received}=$now;$exit->{received_mono}=$mono;
    GP_Process($s,$cfg,$exit,$now,$mono);
    is($s->{arrival}{event}{key},$latest->{key},'interruption restarts at the actually newer Home entry');
    is($s->{arrival}{start_mono},$latest->{received_mono},'restart retains that entry\'s original receipt');
    is($s->{arrival}{motion},'unknown','motion before the intervening exit is not carried over');
    is($s->{arrival}{due_mono},$latest->{received_mono}+60,'interruption requires a new complete wait');
};

done_testing();
