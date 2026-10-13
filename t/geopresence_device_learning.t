use strict;
use warnings;
use Test::More;
use FindBin;
use MIME::Base64 qw(encode_base64);
use POSIX qw(strftime);

# Self-contained FHEM boundary: no network, active devices or state files.
our (%defs,%attr,%data,%keys,$init_done,$readingFnAttributes,$unicodeEncoding);
our ($now,$mono,@config_commands,@outputs,$attr_error,$after_attr);
$readingFnAttributes=''; $unicodeEncoding=1;
sub setReadingsVal { $_[0]{READINGS}{$_[1]}={VAL=>$_[2],TIME=>$_[3]}; }
sub InternalTimer { }
sub RemoveInternalTimer { }
sub getKeyValue { return (undef,$keys{$_[0]}); }
sub setKeyValue { $keys{$_[0]}=$_[1]; return; }
sub Log3 { }
sub CommandSet { push @outputs,[@_]; return; }
sub pushMsg { push @outputs,[@_]; return; }
sub readingsBeginUpdate { push @outputs,[@_]; }
sub readingsBulkUpdate { push @outputs,[@_]; }
sub readingsEndUpdate { push @outputs,[@_]; }
sub CommandAttr {
    my ($client,$text)=@_;
    push @config_commands,$text;
    return $attr_error if $attr_error;
    my ($name,$key,$value)=split / /,$text,3;
    my $error=GeoPresence_Attr('set',$name,$key,$value);
    return $error if $error;
    $attr{$name}{$key}=$value;
    $after_attr->() if $after_attr;
    return '';
}
require "$FindBin::Bin/../FHEM/98_GeoPresence.pm";
{
    no warnings qw(redefine once);
    *GP_Now=sub {$now}; *GP_Mono=sub {$mono};
}
my $password='test-password-123456789012345';
sub define_device {
    my ($name,$definition)=@_;
    $defs{$name}={NAME=>$name,TYPE=>'GeoPresence'};
    my $error=GeoPresence_Define($defs{$name},"$name GeoPresence $definition");
    die $error if $error;
    return $defs{$name};
}
sub fixture {
    %defs=(); %attr=(); %data=(); %keys=(); @config_commands=(); @outputs=();
    $attr_error=undef; $after_attr=undef; $init_done=0; $now=1790000000; $mono=1000;
    my $c=define_device('GP','controller'); $attr{GP}={webhookPort=>8090}; GP_StoreMode($defs{GP},'debug');
    for my $r (qw(Tavi Other)) {
        $defs{'rr_'.$r}={NAME=>'rr_'.$r,TYPE=>'ROOMMATE',READINGS=>{state=>{VAL=>'home'}}};
        define_device('Geo.'.$r,"resident GP rr_$r");
        $attr{'Geo.'.$r}={sourceMode=>'geofency_phone',webhookUser=>lc($r)}; GP_StoreMode($defs{'Geo.'.$r},'debug');
        $keys{'GeoPresence_Geo.'.$r.'_auth'}='a'x32 . ':'.Digest::SHA::sha256_hex('a'x32 . ':'.$password);
    }
    $init_done=1; GP_ResetController($c); $c->{helper}{gp}{ready}=1;
    return $c;
}
sub ready { $_[0]{helper}{gp}{ready}=1; }
sub start { my $r=$_[1]//'Geo.Tavi'; return GeoPresence_Set($defs{$r},$r,'mode','learning'); }
sub stop { my $r=$_[1]//'Geo.Tavi'; return GeoPresence_Set($defs{$r},$r,'learnConfirm'); }
sub cancel_learning { return GeoPresence_Set($defs{'Geo.Tavi'},'Geo.Tavi','mode','disabled'); }
sub view { return GeoPresence_Get($_[0],'GP','learnedLocations','Geo.Tavi',@_[1..$#_]); }
sub payload {
    my (%override)=@_;
    my %fields=(device=>'TAVI-PHONE',id=>'HOME-ID',name=>'Home',entry=>1,isTest=>'true',
        date=>strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now)),latitude=>49,longitude=>8,radius=>50,%override);
    delete $fields{$_} for grep {!defined $fields{$_}} keys %fields;
    return join '&',map {my $v=$fields{$_};$v =~ s/([^A-Za-z0-9_.~-])/sprintf('%%%02X',ord($1))/eg;"$_=$v"} sort keys %fields;
}
sub post {
    my ($c,$body,%options)=@_;
    my %headers=('content-type'=>'application/x-www-form-urlencoded');
    $headers{authorization}='Basic '.encode_base64(($options{user}//'tavi').':'.($options{password}//$password),'')
        unless $options{no_auth};
    return GP_HTTP($c,$options{method}//'POST',$options{path}//'/fhem/geopresence',\%headers,$body);
}
sub capture {
    my ($c)=@_;
    like(start($c),qr/Learning for 15.*learnConfirm/,'starts without deviceId or locations');
    is((post($c,payload()))[0],200,'first authenticated observation accepted');
}

subtest 'first device and locations, explicit confirmation, readable reports' => sub {
    my $c=fixture();
    like(start($c),qr/Learning for 15.*learnConfirm/,'window explains confirmation');
    is($defs{'Geo.Tavi'}{STATE},'learning','device status identifies active learning');
    like(view($c),qr/Waiting for first authenticated test webhook/,'visible waiting state');
    is(view($c,'format=json'),'[]','legacy JSON starts as an empty location array');
    is((post($c,payload()))[0],200,'first Home event accepted without complete configuration');
    is((post($c,payload(id=>'OUTER-ID',name=>'Surroundings',radius=>4500)))[0],200,'outer zone from the same phone accepted');
    is((post($c,payload()))[0],200,'HTTP retry accepted without another location');
    is(scalar @{JSON::PP::decode_json(view($c,'format=json'))},2,'only two numbered locations retained');
    ok(!exists $attr{'Geo.Tavi'}{deviceId},'HTTP never writes deviceId');
    is_deeply(\@config_commands,[],'HTTP never executes configuration commands');
    like(view($c),qr/Device ID\s+: tavi-phone.*Binding\s+: Not configured/s,'readable candidate and binding state');
    like(view($c,'format=html'),qr/Device learning.*tavi-phone.*Not configured/s,'same identity visible in escaped HTML report');
    like(GeoPresence_Get($c,'GP','locationCommands','Geo.Tavi','@1','home','Geo.Tavi.Home'),qr/Confirm learning.*learnConfirm/,'location registration waits for device confirmation');
    is_deeply($c->{helper}{gp}{queue},[],'learning cannot queue an arrival');
    is_deeply(\@outputs,[],'no readings, status, actuator or notification outputs');
    my $locations=view($c,'format=json');
    like(stop($c),qr/^Learning confirmed; deviceId tavi-phone configured/,'explicit stop confirms candidate');
    is($defs{'Geo.Tavi'}{STATE},'disabled','confirmation leaves the device visibly disabled');
    is_deeply(\@config_commands,['Geo.Tavi deviceId tavi-phone'],'confirmation uses the FHEM attribute command');
    is($attr{'Geo.Tavi'}{deviceId},'tavi-phone','normalized deviceId configured');
    ok(!$c->{helper}{gp}{learning}{'Geo.Tavi'},'reset does not reopen reception');
    is(view($c,'format=json'),$locations,'normal AttrFn reset preserves confirmed locations');
    like(view($c),qr/Binding\s+: Configured.*Reception\s+: Stopped/s,'confirmed report');
    is(GeoPresence_Get($c,'GP','locationCommands','Geo.Tavi','@1','home','Geo.Tavi.Home'),
        "define Geo.Tavi.Home GeoPresence location Geo.Tavi home\nattr Geo.Tavi.Home zoneId home-id",'existing copy/paste workflow resumes');
    like(stop($c),qr/Learning (?:confirmed|already confirmed)/,'repeated stop is harmless');
    is(scalar @config_commands,1,'idempotent confirmation');
    is_deeply(\@outputs,[],'confirmation does not operate devices or update readings');
    GP_ResetController($c);
    is(view($c,'format=json'),$locations,'confirmed results survive a module/session reset');
};

subtest 'only a fully valid authenticated fresh debug event may pin a phone' => sub {
    my $c=fixture(); start($c);
    for my $case (
        [payload(),{no_auth=>1},401,'authentication is required'],
        [payload(),{password=>'wrong'},401,'incorrect password'],
        [payload(),{user=>'unknown'},401,'unknown user'],
        [payload(),{method=>'GET'},405,'GET cannot enroll'],
        [payload(),{path=>'/fhem/geopresence/debug'},404,'removed debug path cannot enroll'],
        [payload(),{path=>'/fhem/geopresence?isTest=true'},404,'query cannot select test processing'],
        [payload(isTest=>''),{},400,'empty test flag'],
        [payload(isTest=>'TRUE'),{},400,'invalid flag spelling'],
        [payload(isTest=>'no'),{},400,'unknown flag value'],
        [payload(isTest=>"true\n"),{},400,'test flag control characters'],
        [payload().'&isTest=false',{},400,'duplicate test flag'],
        [payload().'&istest=true',{},400,'incorrect test field casing'],
        [payload(device=>''),{},422,'missing device'],
        [payload(device=>'phone;set-door'),{},422,'invalid device'],
        [payload(device=>'x'x129),{},422,'oversized identifier'],
        [payload(entry=>2),{},422,'invalid entry'],
        [payload(id=>''),{},422,'missing zone'],
        [payload(radius=>-1),{},422,'invalid geometry'],
        [payload(date=>'not-a-date'),{},422,'invalid time'],
        [payload(date=>strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now-20))),{},422,'event before learning began'],
        [payload(date=>strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now-100))),{},422,'old retry'],
        [payload(date=>strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now+31))),{},422,'future event'],
        [payload().'&cmd=set%20door%20on',{},400,'FHEM command fields remain forbidden'],
        [payload().'&device=OTHER',{},400,'duplicate identity field'],
    ) {
        is((post($c,$case->[0],%{$case->[1]}))[0],$case->[2],$case->[3]);
        is(GP_Learned($c,'Geo.Tavi')->{device},'','rejected request pins no device');
        is(view($c,'format=json'),'[]','rejected request captures no location');
    }
    is((post($c,payload()))[0],200,'valid request still accepted');
    is((post($c,payload(device=>'ANOTHER-PHONE',id=>'WORK-ID')))[0],422,'different phone cannot replace candidate');
    is((post($c,payload(device=>'tavi-phone',id=>'WORK-ID')))[0],200,'same phone, different case, can add a zone');
    ok(!exists $attr{'Geo.Tavi'}{deviceId},'still only a candidate');
    is_deeply(\@outputs,[],'all paths stay isolated');
};

subtest 'only explicit test observations participate in enrollment on the single URL' => sub {
    my $c=fixture(); start($c);
    for my $value (undef,'false','0') {
        is_deeply([post($c,payload(isTest=>$value))],[200,'OK ignored during learning; isTest=true required; no actions'],
            'real observation acknowledged without becoming a setup candidate');
        is(GP_Learned($c,'Geo.Tavi')->{device},'','no implicit phone learning');
        is(view($c,'format=json'),'[]','real observation does not enroll a location');
        is_deeply($c->{helper}{gp}{queue},[],'real observation not queued during learning');
    }
    is((post($c,payload(isTest=>'1')))[0],200,'explicit numeric true also accepted');
    my $list=view($c,'format=json');
    is((post($c,payload(isTest=>'false',id=>'REAL-WORK')))[0],200,'real observation after a test is still ignored');
    is(view($c,'format=json'),$list,'real observation cannot append to a pinned phone');
    like(stop($c),qr/deviceId tavi-phone configured/,'the test capture is confirmed');
    is_deeply(\@outputs,[],'enrollment has no productive outputs');
};

subtest 'credentials and device identities are unique across residents' => sub {
    my $c=fixture();
    delete $attr{'Geo.Tavi'}{webhookUser};
    like(start($c),qr/unique webhookUser/,'requires an authentication mapping');
    $attr{'Geo.Tavi'}{webhookUser}='other';
    like(start($c),qr/unique webhookUser/,'rejects ambiguous user');
    $attr{'Geo.Tavi'}{webhookUser}='tavi';
    delete $keys{'GeoPresence_Geo.Tavi_auth'}; GP_ResetController($c);
    like(start($c),qr/stored webhookPassword/,'requires stored credentials');
    like(GeoPresence_Set($defs{'Geo.Tavi'},'Geo.Tavi','webhookPassword',$password),qr/stored/,'password configured before learning');
    ready($c); $attr{'Geo.Other'}{deviceId}='TAVI-PHONE'; start($c);
    like((post($c,payload()))[1],qr/already assigned to Geo.Other/,'cannot capture an assigned phone');
    is(GP_Learned($c,'Geo.Tavi')->{device},'','collision did not pin candidate');
    delete $attr{'Geo.Other'}{deviceId};
    is((post($c,payload()))[0],200,'free identity accepted');
    like(start($c,'Geo.Other'),qr/Learning for/,'another resident may learn independently');
    like((post($c,payload(),user=>'other'))[1],qr/already being learned for Geo.Tavi/,'two sessions cannot claim the same phone');
    is((post($c,payload(device=>'OTHER-PHONE'),user=>'other'))[0],200,'independent phone accepted');
    $attr{'Geo.Other'}{deviceId}='tavi-phone';
    like(stop($c),qr/already assigned/,'confirmation rechecks identity ownership');
    is_deeply(\@config_commands,[],'conflicting confirmation changes no attributes');
};

subtest 'expiry stops reception but still permits explicit completion' => sub {
    my $c=fixture(); capture($c);
    my $list=view($c,'format=json'); $now+=901; $mono+=901;
    is((post($c,payload(id=>'LATE')))[0],503,'expired enrollment does not become normal debug processing');
    is($defs{'Geo.Tavi'}{STATE},'disabled','learning timeout updates device status without actions');
    is(view($c,'format=json'),$list,'captured data remain available after expiry');
    like(view($c),qr/Reception\s+: Expired/,'timeout visible');
    ok(!exists $attr{'Geo.Tavi'}{deviceId},'timeout cannot confirm identity');
    like(stop($c),qr/deviceId tavi-phone configured/,'user can confirm retained result after timeout');
    $c=fixture(); start($c);
    like(stop($c),qr/No device or location captured/,'empty confirmation is rejected');
    is(GP_Mode('Geo.Tavi'),'learning','failed confirmation allows another test');
    is($defs{'Geo.Tavi'}{STATE},'learning','failed confirmation preserves learning display');
    cancel_learning($c);
    is($defs{'Geo.Tavi'}{STATE},'disabled','explicit cancellation updates device status');
    ok(!GP_Learned($c,'Geo.Tavi'),'empty stop closes and removes pending session');
    is((post($c,payload()))[0],503,'late first event cannot enroll after stop');
    is_deeply(\@config_commands,[],'empty stop never writes a fabricated ID');
};

subtest 'unconfirmed identities are revoked by cancellation and configuration changes' => sub {
    for my $case (
        ['explicit cancellation',sub {cancel_learning($_[0]);}],
        ['resident mode',sub {GeoPresence_Set($defs{'Geo.Tavi'},'Geo.Tavi','mode','disabled');}],
        ['controller mode',sub {GeoPresence_Set($defs{'GP'},'GP','mode','disabled');}],
        ['attribute change',sub {CommandAttr(undef,'Geo.Tavi allowDoor 0');}],
        ['password change',sub {GeoPresence_Set($defs{'Geo.Tavi'},'Geo.Tavi','webhookPassword',$password.'new');}],
        ['module reload',sub {my %module;GeoPresence_Initialize(\%module);}],
        ['resident deleted',sub {GeoPresence_Undef($defs{'Geo.Tavi'});delete $defs{'Geo.Tavi'};}],
        ['FHEM restart',sub {delete $_[0]{helper}{gp};GP_ResetController($_[0]);}],
    ) {
        my $c=fixture(); capture($c); $case->[1]->($c);
        ok(!GP_Learned($c,'Geo.Tavi'),"$case->[0] discards unconfirmed candidate");
        ok(!exists $attr{'Geo.Tavi'}{deviceId},"$case->[0] does not commit a candidate");
        is($defs{'Geo.Tavi'}{STATE},'disabled',"$case->[0] leaves a disabled device display")
            if exists $defs{'Geo.Tavi'};
        is_deeply(\@outputs,[],"$case->[0] has no device outputs");
    }
    my $c=fixture(); capture($c); cancel_learning($c); start($c);
    is(view($c,'format=json'),'[]','new start replaces candidate and locations');
    is((post($c,payload(device=>'REPLACEMENT')))[0],200,'new session can capture another unregistered phone');
};

subtest 'configured phones keep the existing location learning contract' => sub {
    my $c=fixture(); $attr{'Geo.Tavi'}{deviceId}='TAVI-PHONE';
    like(start($c),qr/Learning for 15/,'existing phone starts location-only capture');
    is((post($c,payload(device=>'WRONG')))[0],422,'existing binding cannot be replaced');
    is((post($c,payload()))[0],200,'registered phone accepted case-insensitively');
    my $list=view($c,'format=json');
    like(stop($c),qr/Learning (?:confirmed|already confirmed)/,'stop still only closes known-phone reception');
    is_deeply(\@config_commands,[],'existing device attribute not rewritten');
    GP_ResetController($c);
    is(view($c,'format=json'),$list,'known-phone results remain across reset');
    $defs{GP}{READINGS}{mode}{VAL}='active';
    like(start($c),qr/Learning for 15/,'active controller allows resident learning');
    cancel_learning($c);
    $defs{GP}{READINGS}{mode}{VAL}='debug'; $attr{'Geo.Tavi'}{sourceMode}='phone_only';
    like(start($c),qr/Geofency source/,'phone-only resident cannot capture Geofency');
};

subtest 'failed attribute commit is reported and can be retried' => sub {
    my $c=fixture(); capture($c); $attr_error='Test attribute rejection';
    like(stop($c),qr/Cannot confirm device identifier: Test attribute rejection/,'FHEM rejection reaches the user');
    ok(!exists $attr{'Geo.Tavi'}{deviceId},'failed commit leaves no binding');
    ok(GP_Learned($c,'Geo.Tavi')->{unbound},'candidate retained after rejected commit');
    $attr_error=undef;
    like(stop($c),qr/deviceId tavi-phone configured/,'explicit retry succeeds');
    $c=fixture(); capture($c);
    $after_attr=sub {$attr{'Geo.Tavi'}{deviceId}='different';GP_ResetController($c);};
    like(stop($c),qr/confirmation interrupted/,'synchronous external configuration change cannot report a false success');
    ok(!GP_Learned($c,'Geo.Tavi'),'different identity cannot reuse results from the captured phone');
};

subtest 'one endpoint separates real and test observations before state selection' => sub {
    my $c=fixture();
    $attr{'Geo.Tavi'}{deviceId}='tavi-phone';
    $attr{'Geo.Tavi'}{phoneProxies}='proxy';
    $attr{'rr_Tavi'}{rr_locationUnderway}='underway';
    $defs{proxy}={NAME=>'proxy',TYPE=>'PRESENCE'};
    for my $role (qw(home outer)) {
        my $name='Geo.Tavi.'.$role;
        define_device($name,'location Geo.Tavi '.$role);
        $attr{$name}{zoneId}=$role.'-id';
    }
    GP_ResetController($c); ready($c);
    $defs{GP}{READINGS}{mode}{VAL}='active'; $defs{'Geo.Tavi'}{READINGS}{mode}{VAL}='active';
    is_deeply([GP_Validate($c,'Geo.Tavi',1)],[],'complete active resident prepared');
    for my $value ('true','1',undef,'false','0') {
        my $debug=defined($value) && ($value eq 'true' || $value eq '1');
        my $before=JSON::PP->new->canonical->encode($c->{helper}{gp}{prod}//{});
        my @response=post($c,payload(isTest=>$value));
        is_deeply(\@response,[200,$debug?'OK debug accepted; no actions':'OK accepted in current FHEM session'],
            'response identifies the selected processing mode');
        is($c->{helper}{gp}{queue}[-1]{debug},$debug?1:0,'queue selects the correct isolated state');
        is(JSON::PP->new->canonical->encode($c->{helper}{gp}{prod}//{}),$before,'test receipt leaves production state unchanged') if $debug;
    }
    my $queued=scalar @{$c->{helper}{gp}{queue}};
    for my $body (payload(isTest=>''),payload(isTest=>'yes'),payload(isTest=>'TRUE'),
                  payload().'&isTest=false',payload(isTest=>undef).'&istest=true') {
        is((post($c,$body))[0],400,'ambiguous or malformed test marker rejected while active');
    }
    for my $path ('/fhem/geopresence/debug','/fhem/geopresence/','/fhem/geopresence?isTest=true') {
        is((post($c,payload(),path=>$path))[0],404,'only the exact base path accepts requests');
    }
    is((post($c,payload(),no_auth=>1))[0],401,'test flag cannot replace authentication');
    $defs{GP}{READINGS}{mode}{VAL}='disabled';
    is((post($c,payload()))[0],503,'test flag cannot enable a disabled controller');
    $defs{GP}{READINGS}{mode}{VAL}='active'; $defs{'Geo.Tavi'}{READINGS}{mode}{VAL}='disabled';
    is((post($c,payload()))[0],503,'test flag cannot enable a disabled resident');
    is(scalar @{$c->{helper}{gp}{queue}},$queued,'rejected requests do not enter either queue');
    $defs{'Geo.Tavi'}{READINGS}{mode}{VAL}='debug';
    is((post($c,payload(isTest=>'false')))[1],'OK debug accepted; no actions','resident debug still simulates real observations');
    $defs{'Geo.Tavi'}{READINGS}{mode}{VAL}='active'; $defs{GP}{READINGS}{mode}{VAL}='debug';
    is((post($c,payload(isTest=>undef)))[1],'OK debug accepted; no actions','controller debug still simulates legacy real observations');
    is_deeply(\@outputs,[],'HTTP reception does not dispatch productive outputs');
    is(JSON::PP::decode_json(GeoPresence_Get($c,'GP','explain','Geo.Tavi','debug','format=json'))->{test_webhook_isolation},1,
        'test application can verify the shared endpoint contract before sending');
};

subtest 'learning under an active controller leaves the neighbour and listener intact' => sub {
    my $c=fixture();
    GP_StoreMode($c,'active'); GP_StoreMode($defs{'Geo.Other'},'active');
    $attr{'Geo.Other'}{sourceMode}='phone_only'; $attr{'Geo.Other'}{phoneProxies}='proxy';
    $attr{'rr_Other'}{rr_locationUnderway}='underway'; $defs{proxy}={NAME=>'proxy',TYPE=>'PRESENCE'};
    my $other=GP_State($c,'Geo.Other',0); $other->{trip}={armed=>1,id=>'keep-trip'};
    my $runtime=$c->{helper}{gp}; my $listener={marker=>1}; $c->{helper}{gp_http}=$listener;
    capture($c);
    is(GP_EffectiveMode($c,'Geo.Tavi',0),'learning','learning is distinct from simulation');
    is($defs{'Geo.Tavi'}{STATE},'learning','learning resident is visible under an active controller');
    is($defs{'Geo.Other'}{STATE},'active','productive neighbour keeps its active display');
    is($runtime->{prod}{'Geo.Other'},$other,'same neighbour state object');
    is($other->{trip}{id},'keep-trip','neighbour trip remains qualified');
    ok(!exists $runtime->{prod}{'Geo.Tavi'} && !exists $runtime->{debug}{'Geo.Tavi'},'no trip state allocated for learning');
    like(GeoPresence_Set($c,'GP','debugReset','Geo.Tavi'),qr/unavailable during learning/,'debug cannot interfere with enrollment');
    is((post($c,payload(isTest=>'false')))[0],200,'real event deliberately acknowledged and ignored');
    is_deeply($runtime->{queue},[],'no delayed replay after enrollment');
    like(stop($c),qr/Learning confirmed/,'confirmation under active controller');
    is(GP_Mode('Geo.Tavi'),'disabled','confirmation cannot activate person');
    define_device('Z.New','location Geo.Tavi home');
    is(CommandAttr(undef,'Z.New zoneId home-id'),'','own location configured while neighbour active');
    is($other->{trip}{id},'keep-trip','own setup leaves neighbour trip intact');
    like(CommandAttr(undef,'Geo.Other phoneSignalMode state'),qr/affects active residents/,'active neighbour cannot be reconfigured accidentally');
    is($c->{helper}{gp},$runtime,'controller runtime retained');
    is($c->{helper}{gp_http},$listener,'listener remains bound');
    is_deeply(\@outputs,[],'no commands, messages or eventful readings');
};

subtest 'mode precedence, idempotence, failed activation and cancellation' => sub {
    my $c=fixture(); my $r=$defs{'Geo.Tavi'};
    for my $cm (qw(active debug disabled)) {
        for my $rm (qw(active debug disabled learning)) {
            GP_StoreMode($c,$cm); GP_StoreMode($r,$rm);
            my $expected=$cm eq 'disabled'||$rm eq 'disabled'?'disabled':$rm eq 'learning'?'learning':$cm eq 'debug'||$rm eq 'debug'?'debug':'active';
            is(GP_EffectiveMode($c,'Geo.Tavi',0),$expected,"$cm / $rm precedence");
            is(GP_EffectiveMode($c,'Geo.Tavi',1),$expected eq 'active'?'debug':$expected,'test flag only removes productive authority');
        }
    }
    $c=fixture(); $r=$defs{'Geo.Tavi'};
    GP_StoreMode($c,'active'); GP_StoreMode($r,'disabled');
    like(GeoPresence_Set($r,'Geo.Tavi','mode','active'),qr/Cannot activate/,'incomplete activation rejected');
    is(GP_Mode('Geo.Tavi'),'disabled','failed activation leaves mode unchanged');
    capture($c); my $capture=GP_Learned($c,'Geo.Tavi'); my $until=$capture->{until};
    $mono+=10; $now+=10; is(start($c),undef,'same mode idempotent');
    is(GP_Learned($c,'Geo.Tavi'),$capture,'same mode retains capture');
    is($capture->{until},$until,'same mode does not extend reception');
    $mono+=901; $now+=901; GP_ExpireLearning($c,'Geo.Tavi');
    is(GP_Mode('Geo.Tavi'),'disabled','expiry disables resident');
    ok(GP_Learned($c,'Geo.Tavi'),'expiry retains data for review');
    cancel_learning($c); ok(!GP_Learned($c,'Geo.Tavi'),'explicit disabled cancels even after expiry');
    like(GeoPresence_Attr('set','GP','mode','debug'),qr/Use set/,'old controller attribute rejected');
    like(GeoPresence_Attr('set','Geo.Tavi','operatingMode','debug'),qr/Use set/,'old resident attribute rejected');
    delete $defs{GP};
    like(GeoPresence_Set($r,'Geo.Tavi','mode','debug'),qr/Controller unavailable/,'orphaned resident cannot start a session');
    like(GeoPresence_Set($r,'Geo.Tavi','learnConfirm'),qr/Controller unavailable/,'orphaned resident cannot confirm learning');
};

subtest 'shared changes guard all affected active residents' => sub {
    my $c=fixture(); GP_StoreMode($c,'active'); GP_StoreMode($defs{'Geo.Other'},'active');
    my $other=GP_State($c,'Geo.Other',0); $other->{trip}={armed=>1,id=>'keep'};
    define_device('A.Shared','action GP switch_on'); $attr{'A.Shared'}{target}='light';
    define_device('R.Shared','rule GP'); $attr{'R.Shared'}{residents}='Geo.Tavi,Geo.Other'; $attr{'R.Shared'}{action}='A.Shared';
    like(CommandAttr(undef,'R.Shared residents Geo.Tavi'),qr/Geo.Other/,'removing active member cannot bypass guard');
    like(CommandAttr(undef,'A.Shared target different'),qr/Geo.Other/,'shared actor guarded');
    define_device('A.Other','action GP switch_on');
    like(CommandAttr(undef,'A.Other target light'),qr/Geo.Other/,'physical target alias cannot bypass guard');
    like(GeoPresence_Undef($defs{'A.Shared'}),qr/Geo.Other/,'shared actor deletion guarded');
    is($other->{trip}{id},'keep','rejections preserve neighbour trip');
};

subtest 'confirmed learning prepares registered geometry without simulating visits' => sub {
    my $c=fixture(); $attr{'Geo.Tavi'}{sourceMode}='geofency_only';
    GP_StoreMode($c,'active'); capture($c);
    is((post($c,payload(id=>'OUTER-ID',radius=>4500)))[0],200,'capture outer geometry');
    like(stop($c),qr/Learning confirmed/,'explicitly confirm setup');
    for my $role (qw(home outer)) {
        define_device('Z.'.$role,'location Geo.Tavi '.$role);
        is(CommandAttr(undef,'Z.'.$role.' zoneId '.$role.'-id'),'','register location from capture');
    }
    ok(GP_Config($c,'Geo.Tavi',1)->{geometry_ready},'confirmed capture supplies reviewable geometry');
    ok(!GP_Config($c,'Geo.Tavi',0)->{geometry_ready},'capture alone does not persist production geometry');
    like(GeoPresence_Set($c,'GP','applyGeometry','Geo.Tavi'),qr/Geometry applied for 2/,'explicit metadata confirmation while resident remains disabled');
    is(GP_Mode('Geo.Tavi'),'disabled','applying geometry cannot enable presence processing');
    is_deeply(\@outputs,[],'no eventful readings, visits, commands or messages');
    delete $c->{helper}{gp}; GP_ResetController($c);
    ok(GP_Config($c,'Geo.Tavi',0)->{geometry_ready},'ordinary geometry readings suffice after loss of transient capture');
    ok(!GP_Learned($c,'Geo.Tavi'),'runtime loss does not recreate enrollment');
};

subtest 'unfinished private configuration cannot suspend an unrelated active resident' => sub {
    my $c=fixture(); GP_StoreMode($c,'active'); GP_StoreMode($defs{'Geo.Other'},'active');
    $attr{'Geo.Other'}{sourceMode}='phone_only'; $attr{'Geo.Other'}{phoneProxies}='proxy';
    $attr{'rr_Other'}{rr_locationUnderway}='underway'; $defs{proxy}={NAME=>'proxy',TYPE=>'PRESENCE'};
    define_device('R.Unfinished','rule GP');
    define_device('A.New1','action GP switch_on'); $attr{'A.New1'}{target}='new-target';
    define_device('A.New2','action GP garage_open'); $attr{'A.New2'}{target}='new-target';
    is_deeply([GP_Validate($c,'Geo.Other',1)],[],'unrelated rule and action errors do not stop current resident');
    is_deeply([GP_Validate($c,undef,1)],[],'controller activation checks only productive scope');
    like(join('; ',GP_Validate($c)),qr/R.Unfinished: residents required/,'full review still reports unfinished rules');
    like(join('; ',GP_Validate($c)),qr/Conflicting action definitions for new-target/,'full review still reports action conflict');
    my $before=$c->{helper}{gp};
    is(GeoPresence_Set($c,'GP','mode','debug'),undef,'global pause works');
    is($c->{helper}{gp},$before,'global mode changes also retain controller runtime and listener ownership');
};

done_testing();
