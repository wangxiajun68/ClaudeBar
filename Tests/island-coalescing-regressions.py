#!/usr/bin/env python3
"""Execute real island scheduling methods with a paused in-memory index.
No windows, timers, user index, network or hardware are opened.
"""
from pathlib import Path
import argparse
import json
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser()
p.add_argument('--probe',action='store_true',help='Report baseline violations without asserting')
p.add_argument('--output-json',type=Path)
a=p.parse_args()

def decl(text,marker):
    start=text.index(marker); end=text.index('{',start)+1; depth=1
    while depth:
        depth+=(text[end]=='{')-(text[end]=='}');end+=1
    return text[start:end]
model=(root/'Sources/ClaudeBar/Models/IslandLiveModel.swift').read_text()
controller=(root/'Sources/ClaudeBar/NotchIslandController.swift').read_text()
methods=decl(model,'    private func reloadSessionCosts(').replace('private func','func')
if 'private func sessionCostRequests(' in model:methods+='\n'+decl(model,'    private func sessionCostRequests(')
fields='\n'.join(line for line in model.splitlines() if 'private var sessionCost' in line)
swift=r'''
import Foundation
enum UsageSource: Hashable { case claude,codex }
enum Agent { case claude,codex,cursor }
struct Session { let id: String; let agent: Agent; let sessionId: String }
enum ModelPricing { struct Estimate: Equatable { let value: Int }; static func estimate(_ usage:[Int])->Estimate { .init(value:usage.reduce(0,+)) } }
enum UsageIndex {
    static let lock=NSLock(), gate=DispatchSemaphore(value:0)
    static var calls=0, active=0, maxActive=0, value=1
    static func setValue(_ newValue:Int) { lock.lock();value=newValue;lock.unlock() }
    static func count()->Int { lock.lock();defer{lock.unlock()};return calls }
    static func fetchSessionFamilies(source:UsageSource,sessionIds:[String])->[String:[Int]] {
        lock.lock();calls+=1;let first=calls==1;let captured=value;active+=1;maxActive=max(maxActive,active);lock.unlock()
        if first { _=gate.wait(timeout:.now()+5) }
        Thread.sleep(forTimeInterval:0.001)
        lock.lock();active-=1;lock.unlock()
        return Dictionary(uniqueKeysWithValues:sessionIds.map{($0,[captured])})
    }
}
@MainActor final class Fixture {
    var sessions:[Session]=[]
    var sessionCosts:[String:ModelPricing.Estimate]=[:]
    FIELDS
    METHODS
}
@MainActor final class Preferences { var notchIslandEnabled=false }
@MainActor final class RefreshModel { var enabled=false; func setPeriodicRefresh(_ enabled:Bool){self.enabled=enabled} }
struct IslandStyle { static let morphSpring=0 }
func withAnimation(_ value:Int,_ apply:()->Void){apply()}
@MainActor final class State { var showsWings=false }
@MainActor final class ControllerFixture {
    let prefs=Preferences();var model:RefreshModel?=RefreshModel();var state:State?=State()
    WINGS
}
func require(_ ok:@autoclosure()->Bool,_ message:String){if !ok(){if PROBE{print("BASELINE VIOLATION:",message)}else{fatalError(message)}}}
@main struct Regression {
    @MainActor static func until(_ condition:()->Bool)async{
        for _ in 0..<3000 { if condition(){return};try? await Task.sleep(for:.milliseconds(1)) }
        fatalError("fixture did not settle")
    }
    @MainActor static func main()async{
        let fixture=Fixture()
        fixture.sessions=[.init(id:"first",agent:.claude,sessionId:"first")]
        fixture.reloadSessionCosts()
        await until{UsageIndex.count()==1}
        UsageIndex.setValue(3)
        for i in 0..<100 {
            fixture.sessions=[.init(id:"latest-\(i)",agent:.claude,sessionId:"latest-\(i)")]
            fixture.reloadSessionCosts()
        }
        try? await Task.sleep(for:.milliseconds(80))
        let before=UsageIndex.count()
        require(before==1,"reload burst admitted overlapping queries while first pass was blocked")
        UsageIndex.gate.signal()
        await until{fixture.sessionCosts["latest-99"] != nil}
        try? await Task.sleep(for:.milliseconds(20))
        let after=UsageIndex.count()
        require(after==2,"100 refreshes must coalesce into one latest trailing pass")
        require(fixture.sessionCosts.count==1 && fixture.sessionCosts["latest-99"]?.value==3,"obsolete request published")
        let island=ControllerFixture()
        island.applyWings(true)
        require(island.model?.enabled==false,"disabled island restarted wing refresh timer")
        island.prefs.notchIslandEnabled=true;island.applyWings(true)
        require(island.model?.enabled==true,"enabled wings must refresh")
        island.applyWings(false)
        require(island.model?.enabled==false,"hidden wings must stop refresh")
        fixture.sessions=[.init(id:"cursor",agent:.cursor,sessionId:"cursor")]
        fixture.reloadSessionCosts()
        await until{fixture.sessionCosts.isEmpty}
        require(UsageIndex.count()==after,"Cursor-only state must not query unsupported cost families")
        let beforeBurst=UsageIndex.count()
        for i in 0..<100 {
            fixture.sessions=[.init(id:"queued-\(i)",agent:.codex,sessionId:"queued-\(i)")]
            fixture.reloadSessionCosts()
        }
        await until{fixture.sessionCosts["queued-99"] != nil}
        require(UsageIndex.count()==beforeBurst+1,"burst before task startup should already use latest input")
        print("METRICS", "{\"queries_before_release\":\(before),\"queries_for_101_refreshes\":\(after),\"maximum_concurrent_queries\":\(UsageIndex.maxActive)}")
        print(PROBE ? "Baseline probe completed" : "PASS: single in-flight query, latest trailing pass, stale result rejection, Cursor-only clear and disabled wing timer")
    }
}
'''.replace('FIELDS',fields).replace('METHODS',methods).replace('WINGS',decl(controller,'    private func applyWings(').replace('private func','func')).replace('PROBE',str(a.probe).lower())
with tempfile.TemporaryDirectory(prefix='claudebar-island-coalescing-')as folder:
    source=Path(folder)/'Regression.swift';source.write_text(swift);binary=Path(folder)/'regression'
    subprocess.run(['swiftc','-O','-parse-as-library',str(source),'-o',str(binary)],check=True)
    output=subprocess.check_output([str(binary)],text=True);print(output,end='')
    metrics=json.loads(next(line[8:]for line in output.splitlines()if line.startswith('METRICS ')))
    if a.output_json:a.output_json.write_text(json.dumps(metrics,indent=2)+'\n')
