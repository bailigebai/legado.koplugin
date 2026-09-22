local A=require('assertions')
local n=0
local function eq(a,b,m) n=n+1;A.equal(a,b,m) end
local loaded,Statistics=pcall(require,'legado.lib.koreader_statistics')
eq(true,loaded,'whole-book KOReader statistics bridge is available')
local now,opens,writes=100,0,0
local fail=false
local saved={}
local store={getOrCreate=function(_,book,md5) opens=opens+1;return md5 end,
    write=function(_,id,periods)
        writes=writes+1
        if fail then return nil,{code='STORAGE_ERROR',message='locked'} end
        for _,period in ipairs(periods) do saved[#saved+1]=period end
        return true
    end}
local function bridge(config)
    return Statistics.new{clock=function() return now end,store=store,settings=config or {is_enabled=true,min_sec=5,max_sec=120}}
end
local b=bridge({is_enabled=false})
eq(false,b:start({id='one'},1),'disabled bridge leaves native statistics disabled')
eq(0,opens,'disabled bridge does not touch database')
b=bridge()
eq(true,b:start({id='chapter-source',name='Book'},100,'stable-book'),'bridge opens stable whole-book identity')
local identity=b.statistics_id
eq(32,#identity,'stable identity is a full MD5')
eq(true,b:start({id='other-source',name='Book'},100,'stable-book'),'same book across chapter/source change reuses active session')
eq(1,opens,'same-book start does not reset the native book')
now=110;eq(true,b:onPageChanged(200),'page event finishes first period')
now=117;eq(true,b:pause(),'pause saves current page before sleep')
eq(2,#saved,'both completed pages are flushed on pause')
eq(10,saved[1].duration,'first page duration retained')
eq(100,saved[1].start_time,'first page timestamp retained')
eq(7,saved[2].duration,'pre-sleep reading saved')
now=1000;eq(true,b:start({id='new-chapter'},300,'stable-book'),'same-book start resumes after chapter pause')
eq(identity,b.statistics_id,'chapter switch preserves native statistics book')
now=1011;eq(true,b:checkpoint(),'checkpoint includes current page')
eq(11,saved[3].duration,'sleep is excluded')
eq(300,saved[3].page,'resumed chapter uses its new virtual page')
eq(1000,saved[3].start_time,'resumed reading starts after sleep')
now=1400;b:close()
eq(120,saved[4].duration,'idle page duration capped')
eq(true,b:close(),'repeat close is safe')
eq(4,#saved,'repeat close never duplicates elapsed time')

b=bridge();now=2000;b:start({id='failed-book'},10)
fail=true;now=2010
eq(nil,b:close(),'failed close reports write error')
eq(1,b:status().pending,'failed close keeps pending period')
eq(true,b:status().closed,'failed close still stops elapsed timer')
local retained=b.statistics_id
eq(nil,b:start({id='new-book'},20),'switching book cannot discard old unsaved periods')
eq(retained,b.statistics_id,'failed switch keeps original statistics identity')
fail=false;now=2020
eq(true,b:close(),'closed bridge can retry pending write')
eq(0,b:status().pending,'successful retry clears only saved periods')
eq(10,saved[#saved].duration,'retry does not add elapsed time after close')
eq(true,b:start({id='new-book'},20),'new book can start after old data saved')

local capped=bridge({is_enabled=true,min_sec=1,max_sec=120})
now=3000;capped:start({id='cap'},1);fail=true
for i=1,500 do now=now+5;capped:onPageChanged(i+1) end
eq(500,capped:status().pending,'failed writes have a finite pending limit')
eq(true,capped:status().blocked,'full pending queue pauses new statistics')
eq('STATISTICS_QUEUE_FULL',capped:status().last_error.code,'queue saturation is explicit')
for i=1,20 do now=now+5;capped:onPageChanged(i+600) end
eq(500,capped:status().pending,'continued reading cannot grow blocked queue')
fail=false
eq(true,capped:checkpoint(),'checkpoint can retry a saturated queue')
eq(false,capped:status().blocked,'successful flush permits new recording')
eq(0,capped:status().pending,'all retained periods were written')
now=now+7;capped:close()
eq(7,saved[#saved].duration,'recording resumes without counting blocked interval')

local suspended=bridge()
now=8000;suspended:start({id='sleep'},1)
now=8010;suspended:pause();local before=#saved
now=9000;suspended:checkpoint();suspended:pause()
eq(before,#saved,'repeated pause and paused checkpoint add no sleeping time')
now=9010;suspended:resume(2)
now=9012;suspended:onPageChanged(3)
now=9020;suspended:close()
eq(8,saved[#saved].duration,'short page below configured minimum is omitted')
eq(before+1,#saved,'only valid resumed period is saved')

G_reader_settings={readSetting=function() return {is_enabled=false} end}
local inherited=Statistics.new{store=store}
local previous_opens=opens
eq(false,inherited:start({id='native-disabled'},1),'native disabled preference is inherited')
eq(previous_opens,opens,'native disabled preference prevents database open')
G_reader_settings=nil

local throwing=bridge()
throwing.store={getOrCreate=function() error('database panic') end}
local ok,err=throwing:start({id='panic'},1)
eq(nil,ok,'dependency panic cannot crash reader')
eq('STATISTICS_ERROR',err.code,'dependency panic has a structured error')
local invalid=bridge();now=0/0
eq(nil,invalid:start({id='bad-clock'},1),'invalid clock cannot enter statistics database')
now=5000;invalid:start({id='fraction-page'},10.9)
now=5002;invalid:onPageChanged(0/0)
now=5010;invalid:close()
eq(10,saved[#saved].page,'nonfinite page retains previous integral virtual page')
eq(10,saved[#saved].duration,'invalid page event does not erase valid elapsed time')
local failed_clock=bridge();now=6000;failed_clock:start({id='old-book'},10)
now=6010;failed_clock:onPageChanged(20)
local completed_period=failed_clock.periods[1]
now=0/0
local closed,clock_error=failed_clock:close()
eq(nil,closed,'invalid closing clock reports failure')
eq('STATISTICS_CLOCK',clock_error.code,'closing clock error remains explicit')
eq(false,failed_clock.active,'closing stops the old book even when the clock fails')
eq(true,failed_clock.closed,'failed closing clock still seals the old session')
eq(nil,failed_clock.period_start,'period without an end timestamp cannot continue later')
eq(1,#failed_clock.periods,'completed pending periods survive a clock failure')
eq(completed_period,failed_clock.periods[1],'clock failure preserves the exact completed period')
now=6100
eq(false,failed_clock:onPageChanged(5001),'new-book page cannot enter a clock-failed old session')
eq(false,failed_clock:resume(5001),'resume cannot reopen a clock-failed old session')
before=#saved
eq(true,failed_clock:close(),'clock recovery can flush the sealed pending periods')
eq(before+1,#saved,'retry never invents a duration for the unfinished period')
eq(10,saved[#saved].duration,'only measured pre-failure reading is saved')
eq(true,failed_clock:start({id='new-book'},5001),'new identity starts normally after recovery')
local live_config={is_enabled=true,min_sec=5,max_sec=120}
local live=bridge(live_config);now=7000;live:start({id='live-settings'},10)
now=7010;live:onPageChanged(20)
live_config.is_enabled=false;now=7020
eq(false,live:onPageChanged(30),'native disable is observed before recording another page')
eq(nil,live.period_start,'native disable drops the unfinished reading timer')
eq(1,#live.periods,'native disable retains only already completed periods')
before=#saved
eq(true,live:checkpoint(),'disabled bridge may flush previously completed periods')
eq(before+1,#saved,'disabled checkpoint writes only the completed pre-disable page')
now=7100;live:pause();live:flush()
eq(before+1,#saved,'disabled lifecycle never adds reading periods')
eq(false,live:start({id='live-settings'},30),'start respects current native disabled setting')
eq(false,live:resume(30),'resume respects current native disabled setting')
live_config.is_enabled=true;live_config.min_sec=2;live_config.max_sec=8;now=7200
eq(true,live:resume(30),'native re-enable can resume the still-open book')
now=7220;live:onPageChanged(40);live:flush()
eq(8,saved[#saved].duration,'native maximum changes apply without rebuilding the bridge')
eq(7200,saved[#saved].start_time,'re-enable excludes the disabled interval')
before=#saved
live_config.min_sec=15;live_config.max_sec=20;now=7230;live:onPageChanged(50);live:flush()
eq(before,#saved,'native minimum changes discard short subsequent periods')
live_config.max_sec=math.huge;live_config.min_sec=-100;live:flush()
eq(120,live.max_sec,'nonfinite runtime maximum uses the native default')
eq(0,live.min_sec,'negative runtime minimum remains bounded')
live_config.max_sec=999999;live_config.min_sec=999999;live:flush()
eq(7200,live.max_sec,'runtime maximum respects the native upper limit')
eq(120,live.min_sec,'runtime minimum respects the native upper limit')
local initially_disabled={is_enabled=false}
local reenabled=bridge(initially_disabled)
eq(false,reenabled:start({id='reenabled'},1),'initial native disable is retained')
initially_disabled.is_enabled=true
eq(true,reenabled:start({id='reenabled'},1),'later native enable permits a first start')
return n
