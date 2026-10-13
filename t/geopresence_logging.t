use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use Encode qw(encode decode);
use JSON::PP;
use Storable qw(dclone);

our (%defs,%attr,%data,%selectlist,$init_done,$readingFnAttributes,$unicodeEncoding);
my (@normal,@sets,@messages,$set_error,$push_error);
sub Log3 { push @normal, [@_]; }
sub CommandSet { push @sets, $_[1]; return $set_error; }
sub pushMsg { die "mock delivery interface failed\n" if $push_error; push @messages, [@_]; }
sub setNotifyDev { $_[0]{NOTIFYDEV}=$_[1]; }
sub setReadingsVal { $_[0]{READINGS}{$_[1]}={VAL=>$_[2],TIME=>$_[3]}; }
sub InternalTimer { die 'Unexpected timer change'; }
sub RemoveInternalTimer { die 'Unexpected timer removal'; }
sub readingsBeginUpdate { die 'Unexpected Reading update'; }
sub readingsBulkUpdate { die 'Unexpected Reading update'; }
sub readingsEndUpdate { die 'Unexpected Reading event'; }
sub fhem { die 'Unexpected FHEM command'; }

require "$FindBin::Bin/../FHEM/98_GeoPresence.pm";
my $wall=Time::Local::timegm(0,0,12,16,8,2026);
my $mono=1000;
{
    no warnings qw(redefine once);
    *GP_Now=sub {$wall};
    *GP_Mono=sub {$mono};
}
my $dir=tempdir('geopresence-log-XXXXXX',TMPDIR=>1,CLEANUP=>1);
my $number=0;
my ($c,$s,$cfg);
my $r='Geo.Test';
sub fixture {
    ++$number;
    %defs=(); %attr=(); @normal=(); @sets=(); @messages=();
    $set_error=undef; $push_error=0; $init_done=1; $unicodeEncoding=1;
    $wall=Time::Local::timegm(0,0,12,16,8,2026); $mono=1000;
    $c=$defs{'System.GeoPresence'}={NAME=>'System.GeoPresence',TYPE=>'GeoPresence',SUBTYPE=>'controller',helper=>{}};
    $defs{$r}={NAME=>$r,TYPE=>'GeoPresence',SUBTYPE=>'resident',CONTROLLER=>$c->{NAME},ROOMMATE=>'rr_Test'};
    $defs{rr_Test}={NAME=>'rr_Test'};
    $attr{rr_Test}{alias}='Lumo';
    $attr{global}{verbose}=3;
    $attr{$c->{NAME}}={logFile=>"$dir/$number-geopresence-%Y-%m.log"}; GP_StoreMode($defs{$c->{NAME}},'active');
    $defs{$r}{READINGS}{mode}{VAL}='active';
    $s=GP_NewState($wall-100,$mono-100,'test-generation');
    $c->{helper}{gp}={ready=>1,start=>$wall-100,epoch=>8,prod=>{$r=>$s},debug=>{},actors=>{},
        learned=>{$r=>{zones=>{saved=>1}}},learning=>{$r=>1}};
    $cfg={rules=>[],label=>'Lumo',action_max_age=>90,future_tolerance=>30,
        zone_display_max_age=>43200,departure_margin=>200,geometry_ready=>1,
        actor_timeout=>60,motion_max_age=>180,minimum_away=>60,phoneSignalMode=>'state',
        zones=>{Home=>{label=>'Zuhause',role=>'home',lat=>50,lon=>7,radius=>100},
                Garden=>{label=>'Vorgarten',role=>'place',lat=>50,lon=>7,radius=>50}},
        roles=>{home=>['Home']}};
    for my $n (qw(Door Gate Light Contact Feedback State Upper Lower)) { $defs{$n}={NAME=>$n}; }
    @{$attr{Door}}{qw(alias)}=('Haustür');
    @{$attr{Gate}}{qw(alias)}=('Garage');
    @{$attr{Light}}{qw(alias)}=('Vorgartenlicht');
}
sub output { return join "\n",map {$_->[2]} @normal; }
sub file_lines {
    my $path=GP_LogPath($c);
    return [] unless -f $path;
    open my $fh,'<:encoding(UTF-8)',$path or die $!;
    my @lines=<$fh>; close $fh; return \@lines;
}
sub debug_text { return join '',@{file_lines()}; }
sub flush { GP_LogTrace($c,$r,$s,$_[0]//0); }
sub tick { $wall+=$_[0]//1; $mono+=$_[0]//1; }
sub trace { GP_Trace($s,$wall,@_); }
sub attr_change {
    my ($cmd,$key,$value)=@_;
    my $error=GeoPresence_Attr($cmd,$c->{NAME},$key,$value);
    return $error if defined $error;
    if ($cmd eq 'set') { $attr{$c->{NAME}}{$key}=$value; }
    else { delete $attr{$c->{NAME}}{$key}; }
    return;
}
sub event {
    my ($entry,$zone)=@_; tick();
    my $e={kind=>'geo',zone=>$zone//'Garden',entry=>$entry,time=>$wall,received=>$wall,key=>'event-'.$wall};
    GP_Process($s,$cfg,$e,$wall,$mono); flush(); return $e;
}
sub intent {
    my ($kind,$params)=@_;
    $s->{phase}='home';
    $s->{intents}=[{kind=>$kind,rule=>'Geo.Rule.Test',generation=>$s->{generation},
        e=>{time=>$wall,received=>$wall},params=>$params}];
}
sub dispatch { GP_Dispatch($c,$r,$cfg,$s,$_[0]//0,$wall,$mono); flush($_[0]//0); }
sub reading {
    my ($dev,$name,$value)=@_;
    $defs{$dev}{READINGS}{$name}={VAL=>$value,TIME=>POSIX::strftime('%Y-%m-%d %H:%M:%S',localtime($wall))};
}

subtest 'Independent modes and strict file routing' => sub {
    fixture();
    GP_Log($c,5,'decision',{mode=>'active',reason=>'active disabled by auto'});
    is(scalar @{file_lines()},0,'production diagnostics off by default');
    is(scalar @normal,0,'no diagnostic fallback into FHEM');
    $defs{$c->{NAME}}{READINGS}{mode}{VAL}='debug'; $attr{global}{verbose}=0;
    GP_Log($c,5,'decision',{mode=>'debug',reason=>'full detail'});
    like(debug_text(),qr/full detail/,'debug auto includes level 5 even at verbose 0');
    $attr{$c->{NAME}}{debugLog}=0;
    GP_Log($c,2,'http',{mode=>'debug',status=>401,reason=>'suppressed'});
    unlike(debug_text(),qr/suppressed/,'explicit off suppresses debug-mode file output');
    $defs{$c->{NAME}}{READINGS}{mode}{VAL}='active'; $attr{$c->{NAME}}{debugLog}=1;
    GP_Log($c,5,'decision',{mode=>'active',reason=>'production enabled'});
    like(debug_text(),qr/production enabled/,'production diagnosis independently enabled');
    $attr{$c->{NAME}}{verbose}=5;
    GP_Log($c,5,'http',{mode=>'active',reason=>'still file only'});
    is(scalar @normal,0,'verbose 5 never copies diagnostics into FHEM');
    delete $attr{$c->{NAME}}{debugLog};
    GP_Log($c,4,'http',{mode=>'debug',route=>'webhook',isTest=>1,reason=>'test webhook'});
    $defs{$r}{READINGS}{mode}{VAL}='debug';
    GP_Log($c,4,'decision',{resident=>$r,reason=>'debug resident'});
    like(debug_text(),qr/test webhook/,'test webhook selected under active controller');
    like(debug_text(),qr/debug resident/,'debug resident selected under active controller');
    my $status=decode_json(GeoPresence_Get($c,$c->{NAME},'logStatus','format=json'));
    is_deeply([@{$status}{qw(debugLog debugEnabled activeEnabled normal_log verbose)}],
        ['auto',1,0,'FHEM',5],'status distinguishes debug and production output');
    delete $attr{$c->{NAME}}{logFile};
    GP_Log($c,2,'http',{mode=>'debug',route=>'webhook',isTest=>1,reason=>'no file target'});
    is(scalar @normal,0,'missing target never redirects diagnostic data');
    $status=decode_json(GeoPresence_Get($c,$c->{NAME},'logStatus','format=json'));
    is($status->{debugEnabled},0,'status reflects missing target');
};

subtest 'Log attributes preserve active trips, actors and learning' => sub {
    fixture();
    $s->{trip}={id=>'keep-trip',armed=>1};
    $c->{helper}{gp}{actors}{Door}={pending=>1};
    my $before=dclone($c->{helper}{gp}); my $runtime=$c->{helper}{gp};
    for my $value (qw(1 0 auto)) {
        is(attr_change('set','debugLog',$value),undef,'logging switch allowed while active');
        is($c->{helper}{gp},$runtime,'runtime identity preserved');
        is_deeply($c->{helper}{gp},$before,'trip, learning, actor and states unchanged');
    }
    is(attr_change('del','debugLog',undef),undef,'deletion restores default without reset');
    is(attr_change('set','logFile',"$dir/changed-%Y-%m.log"),undef,'path changes do not reset');
    is(attr_change('set','verbose',5),undef,'normal verbosity does not reset');
    is_deeply($c->{helper}{gp},$before,'all diagnostic settings preserve runtime');
    like(GeoPresence_Attr('set',$c->{NAME},'debugLog','true'),qr/must be/,'invalid value rejected');
    like(GeoPresence_Attr('set',$c->{NAME},'debugLog',"1\n"),qr/must be/,'control character rejected');
    like(GeoPresence_Attr('set',$r,'debugLog','1'),qr/not valid/,'controller-only setting');
    is_deeply(\@sets,[],'no commands'); is_deeply(\@messages,[],'no messages');
};

subtest 'Readable zone changes; reject duplicates and stale observations' => sub {
    fixture(); $attr{$c->{NAME}}{debugLog}=0;
    my $first=event(1);
    like(output(),qr/Lumo: Entered area “Vorgarten”\./,'entry uses person and zone labels');
    is(scalar @normal,1,'one entry');
    GP_Process($s,$cfg,$first,$wall,$mono); flush();
    event(1);
    is(scalar @normal,1,'duplicate and newer same-state observation are quiet');
    event(0);
    like(output(),qr/Left area “Vorgarten”\./,'exit logged');
    is(scalar @normal,2,'one exit');
    tick();
    GP_Process($s,$cfg,{%$first,time=>$wall-200,received=>$wall,key=>'stale'},$wall,$mono); flush();
    is(scalar @normal,2,'stale event not described as a fresh entry');
    is(scalar @{file_lines()},0,'normal actions work with debugLog off');
    unlike(output(),qr/decision|generation|observed|\{/, 'normal log contains no debug metadata');
    flush(); is(scalar @normal,2,'timer does not replay action tail');
    $attr{$c->{NAME}}{debugLog}=1; flush();
    is(scalar @{file_lines()},0,'enabling does not replay old trace');
    event(1);
    like(debug_text(),qr/zone observation processed/,'new production diagnostics now written');
    is(scalar @normal,3,'new entry still logged once');
};

subtest 'Phone state summaries and normal verbose filter' => sub {
    fixture();
    my $e={kind=>'phone_present',time=>$wall,received=>$wall,key=>'phone-1'};
    GP_Process($s,$cfg,$e,$wall,$mono); flush();
    like(output(),qr/Arrived home \(phone detected\)/,'phone arrival summary');
    tick(); GP_Process($s,$cfg,{%$e,time=>$wall,received=>$wall,key=>'phone-2'},$wall,$mono); flush();
    is(scalar @normal,1,'continuous phone presence not repeated');
    tick();
    my $away={kind=>'phone_absent',time=>$wall,received=>$wall,generation=>$s->{generation},
        negative_generation=>$s->{phone}{negative_generation},negative_wall=>$wall,negative_since=>$mono};
    GP_Process($s,$cfg,$away,$wall,$mono); flush();
    like(output(),qr/Marked absent \(phone absence confirmed\)/,'qualified phone absence summary');
    GP_Process($s,$cfg,$away,$wall,$mono); flush();
    is(scalar @normal,2,'absence status not repeated');
    $attr{$c->{NAME}}{verbose}=2; $attr{$c->{NAME}}{debugLog}=1;
    event(1);
    is(scalar @normal,2,'verbose 2 hides normal actions');
    like(debug_text(),qr/observation received/,'verbose 2 does not hide detail file');
};

subtest 'Production notifications and switches report actual handoff' => sub {
    fixture();
    intent('notify',{message=>'%resident% kommt nach Hause',channel=>0,priority=>0}); dispatch();
    is_deeply(\@messages,[[0,0,'Lumo kommt nach Hause']],'real notification adapter called once');
    like(output(),qr/Notification handed to SmartHome: “Lumo kommt nach Hause”/,'human message with service and text');
    $push_error=1;
    intent('notify',{message=>'Nicht gesendet',channel=>2}); dispatch();
    like(output(),qr/Could not hand notification to SmartAdmin/,'failed handoff not logged as sent');
    is($normal[-1][1],2,'notification failure at level 2');
    intent('switch_on',{target=>'Light',command=>'on'}); dispatch();
    is($sets[-1],'Light on','unchanged fixed switch command');
    like(output(),qr/Switch-on requested for “Vorgartenlicht”/,'switch request accurately described');
    $set_error='mock error'; intent('switch_on',{target=>'Light',command=>'on'}); dispatch();
    like(output(),qr/Switch-on failed for “Vorgartenlicht”/,'failed switch not claimed successful');
};

subtest 'Real opening requests and feedback are distinguished' => sub {
    fixture();
    reading('Contact','state','closed'); reading('Feedback','pulse_state','idle');
    intent('door_open',{target=>'Door',command=>'lock unlocked',contact=>'Contact',feedbackDevice=>'Feedback'}); dispatch();
    is($sets[-1],'Door lock unlocked','door actuator command unchanged');
    like(output(),qr/Door opening requested for “Haustür”/,'door request summary');
    unlike(output(),qr/is open|confirmed the opening pulse/,'dispatch not physical confirmation');
    tick(); reading('Feedback','pulse_state','confirmed'); GP_ActorFeedback($c,$wall,$mono); flush();
    like(output(),qr/Door opener “Haustür” confirmed the opening pulse/,'fresh pulse feedback identified');
    is($s->{door_result},'confirmed','actor state preserved');
    ok(!exists $c->{helper}{gp}{actors}{Door},'confirmed reservation cleared');
    reading('State','state','off'); reading('Upper','state','open'); reading('Lower','state','closed');
    intent('garage_open',{target=>'Gate',command=>'on',stateDevice=>'State',upperContact=>'Upper',lowerContact=>'Lower'}); dispatch();
    like(output(),qr/Garage opening requested for “Garage”/,'garage request summary');
    tick(); reading('State','state','on'); reading('Upper','state','closed'); reading('Lower','state','open');
    GP_ActorFeedback($c,$wall,$mono); flush();
    like(output(),qr/Garage “Garage” is open/,'fresh open end position confirmed');
    for my $case (['failed','failed'],['cancelled','cancelled'],['uncertain','ended without confirmation']) {
        trace('actor feedback',{target=>'Door',kind=>'door_open',result=>$case->[0]}); flush();
        like($normal[-1][2],qr/\Q$case->[1]\E/,'terminal result '.$case->[0].' readable');
        is($normal[-1][1],2,'terminal non-success at level 2');
    }
    $set_error='mock command failed'; reading('Feedback','pulse_state','idle');
    intent('door_open',{target=>'Door',command=>'lock unlocked',contact=>'Contact',feedbackDevice=>'Feedback'}); dispatch();
    like($normal[-1][2],qr/Could not request door opening/,'failed door dispatch accurately logged');
};

subtest 'Simulation cannot appear as real actions or trigger outputs' => sub {
    fixture(); $defs{$c->{NAME}}{READINGS}{mode}{VAL}='debug';
    for my $kind (qw(notify switch_on door_open garage_open)) {
        intent($kind,{target=>'Door',command=>'on',message=>'Simulation'}); dispatch(1);
    }
    trace('zone observation processed',{diagnostic_only=>1,zone=>'Garden',zone_label=>'Vorgarten',entry=>1,changed=>1}); flush(1);
    is_deeply(\@sets,[],'no simulated actuator output');
    is_deeply(\@messages,[],'no simulated notifications');
    is_deeply(\@normal,[],'no simulated action in production log');
    like(debug_text(),qr/would execute; debug suppressed/,'plans in dedicated file');
    like(debug_text(),qr/"mode":"debug"/,'debug provenance retained');
    $attr{$c->{NAME}}{debugLog}=0;
    trace('diagnostic remains in memory'); flush(1);
    unlike(debug_text(),qr/diagnostic remains in memory/,'off suppresses file');
    is($s->{trace}[-1]{reason},'diagnostic remains in memory','off retains in-memory trace');
};

subtest 'Privacy, single-line output, and separate diagnostic rate limit' => sub {
    fixture(); $attr{$c->{NAME}}{debugLog}=1;
    GP_Log($c,5,'observation',{mode=>'active',reason=>"reason\nnewline",body=>'SECRET_BODY',password=>'SECRET_PASSWORD',
        authorization=>'SECRET_AUTH',zone_position=>{lat=>50,lon=>7},message=>'SECRET_MESSAGE',result=>'confirmed'});
    is(scalar @{file_lines()},1,'diagnostic newline safely encoded');
    unlike(debug_text(),qr/SECRET_|zone_position/, 'sensitive/unselected fields excluded');
    like(debug_text(),qr/"result":"confirmed"/,'actor result in diagnosis');
    $attr{rr_Test}{alias}="Lumo\r\nForged\x{2028}line";
    $attr{Light}{alias}="Light\nNew line";
    intent('switch_on',{target=>'Light',command=>'on'}); dispatch();
    unlike($normal[-1][2],qr/[\r\n\x{2028}]/,'human labels cannot inject log lines');
    for (1..400) { GP_Log($c,5,'decision',{mode=>'active',reason=>'flood'}); }
    is(scalar @{file_lines()},301,'300 entries plus one limit notice');
    like(file_lines()->[-1],qr/log_rate_limit/,'last file entry is suppression notice');
    @normal=(); event(1);
    is(scalar @normal,1,'debug rate limit cannot suppress normal action');
    is(scalar @{file_lines()},301,'debug remains rate-limited');
    tick(60); GP_Log($c,5,'decision',{mode=>'active',reason=>'new window'});
    is(scalar @{file_lines()},302,'diagnostics resume next window');
};

subtest 'Date rotation, write errors and operational warnings' => sub {
    fixture(); $attr{$c->{NAME}}{debugLog}=1;
    GP_Log($c,5,'decision',{reason=>'September'});
    my $oldpath=GP_LogPath($c);
    $wall=Time::Local::timegm(0,0,12,1,9,2026); $mono+=60;
    GP_Log($c,5,'decision',{reason=>'October'});
    isnt(GP_LogPath($c),$oldpath,'month selects different file');
    ok(-f $oldpath,'previous month retained');
    like(debug_text(),qr/October/,'new month appended');
    attr_change('set','logFile',"$dir/no-such-directory/geopresence.log");
    for (1..4) { GP_Log($c,5,'decision',{reason=>'private diagnostic detail'}); }
    is(scalar @normal,1,'one write warning per minute');
    like(output(),qr/Could not write diagnostic log/,'concise warning');
    unlike(output(),qr/private diagnostic detail|Cannot open|\{/, 'no diagnostic or path-error fallback');
    my $status=decode_json(GeoPresence_Get($c,$c->{NAME},'logStatus','format=json'));
    like($status->{error},qr/Cannot open/,'detailed error queryable');
    tick(60); GP_Log($c,5,'decision',{reason=>'retry'});
    is(scalar @normal,2,'warning renewed only next minute');
    attr_change('set','logFile',"$dir/recovered.log"); GP_Log($c,5,'decision',{reason=>'recovered'});
    is(decode_json(GeoPresence_Get($c,$c->{NAME},'logStatus','format=json'))->{error},'','successful output clears error');
    $attr{$c->{NAME}}{debugLog}=0;
    GP_Log($c,2,'listener_error',{reason=>'private internals'});
    like($normal[-1][2],qr/Could not start webhook listener/,'operational warning with diagnosis off');
    GP_Log($c,2,'configuration_invalid',{resident=>$r,reason=>'private validation internals'});
    like($normal[-1][2],qr/Lumo: Invalid configuration/,'configuration problem concise');
    GP_Log($c,3,'configuration_ready',{resident=>$r,reason=>'private validation internals'});
    like($normal[-1][2],qr/Lumo: Configuration valid again\./,'configuration recovery in English');
    unlike(output(),qr/private/, 'no internal reasons in normal warnings');
};

subtest 'Unicode and bytestream FHEM log text remains valid and readable' => sub {
    for my $unicode (0,1) {
        fixture(); $unicodeEncoding=$unicode;
        my $person='Jörg'; my $zone='Große Straße'; my $lamp='Außenlicht 🌙';
        my $message='Grüße aus der Straße';
        $attr{rr_Test}{alias}=$unicode ? $person : encode('UTF-8',$person);
        $attr{Light}{alias}=$unicode ? $lamp : encode('UTF-8',$lamp);
        $cfg->{zones}{Garden}{label}=$unicode ? $zone : encode('UTF-8',$zone);
        event(1);
        my $line=$normal[-1][2];
        is(utf8::is_utf8($line) ? 1:0,$unicode,'Log3 receives the selected FHEM encoding');
        $line=decode('UTF-8',$line,Encode::FB_CROAK) unless $unicode;
        like($line,qr/\Q$person: Entered area “$zone”.\E/,'UTF-8 bytes decoded before Unicode control filtering');
        intent('switch_on',{target=>'Light',command=>'on'}); dispatch();
        $line=$normal[-1][2];$line=decode('UTF-8',$line,Encode::FB_CROAK) unless $unicode;
        like($line,qr/\QSwitch-on requested for “$lamp”.\E/,'actor alias and supplementary Unicode character preserved');
        intent('notify',{message=>$unicode ? $message : encode('UTF-8',$message),channel=>0}); dispatch();
        $line=$normal[-1][2];$line=decode('UTF-8',$line,Encode::FB_CROAK) unless $unicode;
        like($line,qr/\Q$message\E/,'configured notification text is readable');
        my $unsafe="Grüße\n\x{2028}Zusatz";
        $attr{rr_Test}{alias}=$unicode ? $unsafe : encode('UTF-8',$unsafe);
        event(0);
        $line=$normal[-1][2];$line=decode('UTF-8',$line,Encode::FB_CROAK) unless $unicode;
        unlike($line,qr/[\r\n\x{2028}]/,'line injection stays excluded in either encoding');
    }
};

done_testing();
