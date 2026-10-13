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
    push @commands,$command;
    $on_command->($command) if $on_command;
    if ($command =~ /^(rr_\w+) state (\w+)$/) { reading($1,'state',$2,$now); }
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
sub getKeyValue { return (undef,$keys{$_[0]}); }
sub setKeyValue { defined($_[1]) ? ($keys{$_[0]}=$_[1]) : delete($keys{$_[0]}); return; }
sub deviceEvents { return $_[0]{CHANGED}; }
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
sub reading { $defs{$_[0]}{READINGS}{$_[1]}={VAL=>$_[2],TIME=>stamp($_[3])}; }
sub device {
    my ($name,$type)=@_;
    $defs{$name}={NAME=>$name,TYPE=>$type,READINGS=>{}};
    return $defs{$name};
}
sub gp_define {
    my ($name,$definition)=@_;
    my $d=device($name,'GeoPresence');
    my $err=GeoPresence_Define($d,"$name GeoPresence $definition");
    die "define $name: $err" if defined $err;
    return $d;
}
sub attribute {
    my ($name,$key,$value)=@_;
    my $err=GeoPresence_Attr('set',$name,$key,$value);
    die "attr $name $key: $err" if defined $err;
    $attr{$name}{$key}=$value;
    return;
}
sub mode { my ($name,$value)=@_; my $error=GeoPresence_Set($defs{$name},$name,'mode',$value); die $error if defined $error; return; }
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
    gp_define('Geo.Test','resident GP rr_Test');
    $attr{'Geo.Test'}={deviceId=>'DEVICE',webhookUser=>'user',sourceMode=>'geofency_phone',phoneProxies=>'p1,p2,p3',phoneSignalMode=>'measurement',allowDoor=>1,allowGarage=>1}; GP_StoreMode($defs{'Geo.Test'},'active');
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
    GP_Process($s,$cfg,ev($zone,$entry,$now,$motion),$now,$mono);
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
sub actor_event {
    my ($c,$device,$key,$value,$time)=@_;
    reading($device,$key,$value,$time//$now);
    local $defs{$device}{CHANGED}=["$key: $value"];
    GeoPresence_Notify($c,$defs{$device}) if grep {$_ eq $device} split /,/,$c->{NOTIFYDEV};
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
    local $c->{helper}{gp}{geometry}{prod}{'Geo.Test'}{'Z.Home'}{radius}=300;
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
    $e={kind=>'phone_present',time=>$now-5,received=>$now,arrival=>1,key=>'older-phone'};
    GP_Process($s,$cfg,$e,$now,$mono);is($s->{phase},'away','older positive cannot replace newer departure');
    is(scalar @{$s->{intents}},0,'no actions from cross-source reorder');
};

subtest 'work role merges overlapping places and waypoint remembers this trip only' => sub {
    my ($c,$cfg)=fixture();
    push @{$cfg->{rules}}, {name=>'workexit',trigger=>'exit',group=>'Work',cooldown=>0,
        action=>'exit',type=>'notify',params=>{message=>'left work'}};
    push @{$cfg->{rules}}, {name=>'place',trigger=>'exit',locations=>['Z.Sternensteg'],afterExit=>'group:Work',cooldown=>0,
        action=>'halfway',type=>'notify',params=>{message=>'halfway'}};
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
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Work',0);
    $now+=3600;GP_TickState($s,$cfg,$now,$mono);
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
    like(join(' ',GP_Validate($c,'Geo.Test',1)),qr/action missing/,'unknown action explained');
    is_deeply([sort keys %defs],\@before,'validation never creates a missing device');
    like(GeoPresence_Attr('set','Z.Home','radius',60),qr/received from Geofency/,'manual geometry is not configuration');
    device('People.Loc.Test','notify');
    like(join(' ',GP_Validate($c,'Geo.Test',1)),qr/disable legacy/,'legacy action must be disabled');
    $attr{rr_Test}{rr_geofenceUUIDs}='DEVICE';
    like(join(' ',GP_Validate($c,'Geo.Test',1)),qr/remove rr_geofenceUUIDs/,'old input binding must be removed');
};

subtest 'disabled rules and duplicate rules do not add hidden actions' => sub {
    my ($c,$cfg)=fixture();$attr{'R.Early'}{enabled}=0;$attr{'R.Late'}{enabled}=0;
    $cfg=GP_Config($c,'Geo.Test');my $s=new_state();advance(40);process($s,$cfg,'Work',0);advance(90);arrive($s,$cfg);
    is_deeply([map {$_->{kind}} @{$s->{intents}}],['door_open'],'no hidden garage rule');
    my ($door)=grep {$_->{type} eq 'door_open'} @{$cfg->{rules}};
    push @{$cfg->{rules}}, {%$door,name=>'anotherRule'};
    $s=new_state();advance(40);process($s,$cfg,'Work',0);advance(90);arrive($s,$cfg);
    is(scalar @{$s->{intents}},1,'same actor deduplicated independently of rule name');
};

subtest 'shared actuator reservations and independent later arrivals' => sub {
    my ($c,$cfg)=fixture();
    # The coordinator accepts intents already authorized by each resident's core.
    device('Geo.Other','GeoPresence');$defs{'Geo.Other'}{SUBTYPE}='resident';$defs{'Geo.Other'}{CONTROLLER}='GP';
    device('rr_Other','ROOMMATE');$defs{'Geo.Other'}{ROOMMATE}='rr_Other';
    $defs{'Geo.Other'}{READINGS}{mode}{VAL}='active';
    my $s1=GP_State($c,'Geo.Test',0);my $s2=GP_State($c,'Geo.Other',0);
    advance(40);process($_,$cfg,'Work',0) for ($s1,$s2);advance(90);actor_fresh();
    arrive($_,$cfg) for ($s1,$s2);
    GP_Dispatch($c,'Geo.Test',$cfg,$s1,0,$now,$mono);GP_Dispatch($c,'Geo.Other',$cfg,$s2,0,$now,$mono);
    is(scalar(grep {$_ eq 'door lock unlocked'} @commands),1,'two residents share one pending door action');
    is(scalar(grep {$_ eq 'garage on'} @commands),1,'two residents share one pending garage action');
    advance(1);reading('feedback','pulse_state','confirmed',$now);GP_ActorFeedback($c,$now,$mono);
    is($s2->{door_result},'confirmed','feedback reaches the second resident');
    advance(40);process($s2,$cfg,'Drive',0);advance(90);actor_fresh();arrive($s2,$cfg);
    GP_Dispatch($c,'Geo.Other',$cfg,$s2,0,$now,$mono);
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
    my ($c,$cfg)=fixture();
    device('Geo.Other','GeoPresence');$defs{'Geo.Other'}{SUBTYPE}='resident';$defs{'Geo.Other'}{CONTROLLER}='GP';
    device('rr_Other','ROOMMATE');$defs{'Geo.Other'}{ROOMMATE}='rr_Other';
    $defs{'Geo.Other'}{READINGS}{mode}{VAL}='active';
    my $s1=GP_State($c,'Geo.Test',0);my $s2=GP_State($c,'Geo.Other',0);
    advance(40);process($_,$cfg,'Work',0) for ($s1,$s2);advance(90.2);actor_fresh();
    reading('feedback','pulse_state','confirmed',$now);
    $on_command=sub {
        return unless $_[0] eq 'door lock unlocked';
        actor_event($c,'feedback','pulse_state','pending');
        actor_event($c,'feedback','pulse_state','confirmed');
    };
    arrive($s1,$cfg);GP_Dispatch($c,'Geo.Test',$cfg,$s1,0,$now,$mono);
    GP_ActorFeedback($c,$now,$mono);
    is($s1->{door_result},'confirmed','feedback inside CommandSet is retained before the first poll');
    advance(0.5);arrive($s2,$cfg);GP_Dispatch($c,'Geo.Other',$cfg,$s2,0,$now,$mono);
    is(scalar(grep {$_ eq 'door lock unlocked'} @commands),2,'later resident gets an independent door pulse');
    GP_ActorFeedback($c,$now,$mono);
    is($s2->{door_result},'confirmed','second pulse is confirmed independently');
};

subtest 'door terminal events survive idle before polling and do not leak to the next pulse' => sub {
    for my $terminal (qw(confirmed failed cancelled)) {
        my ($c,$cfg)=fixture();
        device('Geo.Other','GeoPresence');$defs{'Geo.Other'}{SUBTYPE}='resident';$defs{'Geo.Other'}{CONTROLLER}='GP';
        device('rr_Other','ROOMMATE');$defs{'Geo.Other'}{ROOMMATE}='rr_Other';$defs{'Geo.Other'}{READINGS}{mode}{VAL}='active';
        my $s1=GP_State($c,'Geo.Test',0);my $s2=GP_State($c,'Geo.Other',0);
        advance(40);process($_,$cfg,'Work',0) for ($s1,$s2);advance(90.2);actor_fresh();
        arrive($_,$cfg) for ($s1,$s2);
        GP_Dispatch($c,'Geo.Test',$cfg,$s1,0,$now,$mono);GP_Dispatch($c,'Geo.Other',$cfg,$s2,0,$now,$mono);
        advance(0.1);actor_event($c,'feedback','pulse_state',$terminal);
        advance(0.1);actor_event($c,'feedback','pulse_state','idle');
        is(GP_Read('feedback','pulse_state',''),'idle','contact close resets visible pulse_state before the poll');
        GP_ActorFeedback($c,$now,$mono);
        is($s1->{door_result},$terminal,"first resident keeps $terminal despite idle");
        is($s2->{door_result},$terminal,"shared resident receives $terminal despite idle");
        ok(!$c->{helper}{gp}{actors}{door},'completed door reservation is released');
        advance(1);process($s2,$cfg,'Work',0);advance(61);actor_fresh();arrive($s2,$cfg);
        GP_Dispatch($c,'Geo.Other',$cfg,$s2,0,$now,$mono);
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
    my ($c,$cfg)=fixture();
    device('Geo.Other','GeoPresence');$defs{'Geo.Other'}{SUBTYPE}='resident';$defs{'Geo.Other'}{CONTROLLER}='GP';
    device('rr_Other','ROOMMATE');$defs{'Geo.Other'}{ROOMMATE}='rr_Other';$defs{'Geo.Other'}{READINGS}{mode}{VAL}='active';
    my $s1=GP_State($c,'Geo.Test',0);my $s2=GP_State($c,'Geo.Other',0);
    advance(40);process($_,$cfg,'Work',0) for ($s1,$s2);advance(90.2);actor_fresh();
    arrive($_,$cfg) for ($s1,$s2);
    $on_command=sub {
        return unless $_[0] eq 'door lock unlocked';
        actor_event($c,'feedback','pulse_state','confirmed');
        actor_event($c,'feedback','pulse_state','idle');
    };
    GP_Dispatch($c,'Geo.Test',$cfg,$s1,0,$now,$mono);
    GP_Dispatch($c,'Geo.Other',$cfg,$s2,0,$now,$mono);
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
                $s->{intents}=[{kind=>$kind,generation=>$s->{generation},e=>{time=>$now,received=>$now},params=>$params}];
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
                    $state->{intents}=[map {{kind=>$kind,generation=>$state->{generation},rule=>'actual-output',
                        e=>{time=>$now,received=>$now},params=>$params{$kind}}} 1..2];
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
    my $intent={kind=>'door_open',generation=>$s->{generation},e=>{time=>$now,received=>$now},
        params=>{target=>'door',command=>'lock unlocked',contact=>'contact',feedbackDevice=>'feedback'}};
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
    for my $n (grep {/^Z\./} keys %defs) {delete $defs{$n};delete $attr{$n};}
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

subtest 'idle timer builds each configuration once and still detects changed activation guards' => sub {
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
    is($builds,10,'one configuration build per idle tick, including validation');
    is($validations,10,'validation is not skipped or cached across ticks');
    my $response=GeoPresence_Get($c,'GP','timerStats','format=json');
    my $stats=eval {JSON::PP::decode_json($response)};
    ok(ref($stats) eq 'HASH','read-only timer statistics available');
    if (ref($stats) eq 'HASH') {
        is($stats->{last_device_scans},1,'at most one full device catalogue scan in a tick');
        is($stats->{last_config_builds},1,'statistics show one configuration build');
        cmp_ok($stats->{runs},'>=',11,'statistics count measured callbacks');
    }
    ok(!defined($c->{helper}{gp_work}),'callback catalogue is not retained between timer runs');
    my ($readings_before,$commands_before,$messages_before)=($reading_calls,scalar @commands,scalar @messages);
    GeoPresence_Get($c,'GP','timerStats','format=json');
    is_deeply([$reading_calls,scalar @commands,scalar @messages],[$readings_before,$commands_before,$messages_before],
        'statistics getter produces no readings, commands or messages');
    $defs{GP}{READINGS}{mode}{VAL}='active';
    $attr{rr_Test}{rr_geofenceUUIDs}='external-change';
    advance(1);GeoPresence_Timer($c);
    like(join(' ',@{$c->{helper}{gp}{errors}{'Geo.Test'}}),qr/remove rr_geofenceUUIDs/,
        'next tick notices a changed external ROOMMATE guard without a GeoPresence attribute callback');
    delete $attr{rr_Test}{rr_geofenceUUIDs};
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
    my $cfg=GP_Config($c,'Geo.Test',1);my $s=new_state();advance(40);
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
    $defs{GP}{READINGS}{mode}{VAL}='active';$c->{helper}{gp}{ready}=1;$c->{helper}{gp}{prod}{'Geo.Test'}=$s;
    GP_Dispatch($c,'Geo.Test',$cfg,$s,0,$now,$mono);
    is_deeply(\@commands,['test.dev.licht on'],'active adapter sends exactly the fixed on command');
    is_deeply($c->{helper}{gp}{actors},{},'switch creates no opening reservation');
    advance(1);process($s,$cfg,'Sternensteg',0);advance(1);process($s,$cfg,'Sternensteg',1);
    is(scalar @{$s->{intents}},0,'another visit inside cooldown is suppressed');
    $defs{GP}{READINGS}{mode}{VAL}='debug';
    for my $bad ('on; set door lock unlocked','off','{ exit }') {
        local $attr{'A.Light'}{command}=$bad;
        like(join(' ',GP_Validate($c)),qr/command must be on/,'unbounded command rejected');
    }
    {
        local $attr{'A.Light'}{target}='garage';
        like(join(' ',GP_Validate($c)),qr/Conflicting action definitions/,'light cannot share an opening target');
    }
    {
        local $attr{'R.Light'}{trigger}='arrival';
        like(join(' ',GP_Validate($c)),qr/locations is not applicable/,'arrival rules reject an irrelevant location selector');
    }
    {
        local $attr{'A.Light'}{target}='missing';
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
    my ($motion)=@_;
    my ($c,$cfg)=fixture();my $s=GP_State($c,'Geo.Test',0);
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
        GP_Process($s,$cfg,{kind=>'phone_present',time=>$now,received=>$now,arrival=>$arrival,key=>'new-phone'},$now,$mono);
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
    advance(140);GP_Process($s,$cfg,{kind=>'phone_present',time=>$now,received=>$now,arrival=>1,key=>'later-phone'},$now,$mono);
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
    my ($c,$cfg)=fixture();my $s=new_state();advance(40);process($s,$cfg,'Work',0);advance(140);
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
        elsif ($cancel eq 'clock') {$now+=100;GP_TickState($s,$cfg,$now,$mono);}
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
    my $before=JSON::PP->new->canonical->encode($c->{helper}{gp});
    $defs{'Geo.Second'}={NAME=>'Geo.Second',TYPE=>'GeoPresence',SUBTYPE=>'resident',CONTROLLER=>'GP'};
    $defs{'Geo.Other'}={NAME=>'Geo.Other',TYPE=>'GeoPresence',SUBTYPE=>'resident',CONTROLLER=>'Other'};
    $menu=GeoPresence_Get($c,'GP','?');
    like($menu,qr/Geo\.Second#debug/,'new resident appears without a controller restart');
    unlike($menu,qr/Geo\.Other/,'another controller resident is not offered');
    delete $defs{'Geo.Second'}; delete $defs{'Geo.Test'};
    like(GeoPresence_Get($c,'GP','?'),qr/\bexplain:textField\b/,'empty controller retains usable command discovery');
    is(JSON::PP->new->canonical->encode($c->{helper}{gp}),$before,'dropdown lookup does not allocate state');
    is(scalar @commands,0,'no actuator or ROOMMATE commands'); is(scalar @messages,0,'no notifications');
};

subtest 'Telnet uses separate fields without wrapping text or truncating identifiers' => sub {
    my ($c)=fixture(); my $s=GP_State($c,'Geo.Test',0); $s->{phase}='away'; $s->{door_result}='uncertain';
    delete $attr{'Geo.Test'}{deviceId};
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
        negative_generation=>$s->{phone}{negative_generation}},$now,$mono);
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
    ok(keys(%{$s->{notify_seen}}),'consumed notification history retained');
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

done_testing();
