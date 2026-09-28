#!/usr/bin/env python3
#
# DANGER - this generator is STALE SCAFFOLDING, not a live source of truth.
# It was the original bootstrap for the widget files, but they have since been
# hand-written far beyond what it emits: of the ~30 names here, most no longer
# exist in the repo, and the few that do (RamWidget, SensorBarWidget, ...) have
# diverged to ~10x the size. A plain re-run REPLACES a real, hand-maintained
# widget with a 20-line stub. That happened on 2026-07-17 - a single accidental
# run clobbered RamWidget.qml and dropped three dead stubs into the tree.
#
# So it no longer overwrites anything by default: an existing file is SKIPPED
# (loudly), and you must pass --force to replace it. If you are regenerating a
# genuinely new widget, write the one file; do not --force the whole set.
#
# (AGENTS.md still says "re-run the script to regenerate" - that advice predates
# the divergence and is unsafe now; treat this header as the correction.)
import os
import sys

base = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', 'ui', 'qml', 'widgets')
base = os.path.normpath(base)

FORCE = '--force' in sys.argv[1:]

widgets = {}

# Generic reusable card template
def card(name, icon, content):
    return f'''import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {{
    Layout.fillWidth: true; Layout.fillHeight: true
    radius: 12; color: theme.cardBackground; border.width: 1; border.color: theme.cardBorder
    ColumnLayout {{
        anchors.centerIn: parent; spacing: 4
        Text {{ Layout.alignment: Qt.AlignHCenter; text: "{icon}  {name}"; font.pixelSize: 12; font.bold: true; color: theme.textSecondary }}
        {content}
    }}
}}'''

widgets['RamWidget.qml'] = card('RAM', '🧠', '''property var metrics: ({})
        function fmt(b) { if(b>=1073741824) return (b/1073741824).toFixed(1)+' GB'; if(b>=1048576) return (b/1048576).toFixed(1)+' MB'; return (b/1024).toFixed(0)+' KB' }
        Text { Layout.alignment: Qt.AlignHCenter; text: ((metrics.ram_usage_percent || 0)).toFixed(1)+'%'; font.pixelSize: 28; font.bold: true; font.family: 'monospace'
            color: { var p = metrics.ram_usage_percent || 0; return p > 90 ? theme.error : p > 70 ? theme.warning : theme.accent } }
        Rectangle { Layout.preferredWidth: parent.parent.width*0.7; Layout.preferredHeight: 4; Layout.alignment: Qt.AlignHCenter; radius: 2; color: theme.cardBorder
            Rectangle { height: parent.height; radius: 2; width: parent.width*Math.min(((metrics.ram_usage_percent||0))/100,1.0)
                color: { var p = metrics.ram_usage_percent||0; return p>90?theme.error:p>70?theme.warning:theme.accent } } }
        Text { Layout.alignment: Qt.AlignHCenter; text: fmt(metrics.ram_used_bytes||0)+' / '+fmt(metrics.ram_total_bytes||0); font.pixelSize: 10; color: theme.textSecondary }''')

widgets['SensorBarWidget.qml'] = card('Sensors', '📊', '''property var metrics: ({})
        Text { Layout.alignment: Qt.AlignHCenter; text: 'CPU: '+((metrics.cpu_usage_percent||0).toFixed(0))+'%'; font.pixelSize: 16; font.bold: true; font.family: 'monospace'; color: theme.textPrimary }
        Text { Layout.alignment: Qt.AlignHCenter; text: 'RAM: '+((metrics.ram_usage_percent||0).toFixed(0))+'%'; font.pixelSize: 15; font.family: 'monospace'; color: theme.textSecondary }
        Text { Layout.alignment: Qt.AlignHCenter; visible: (metrics.cpu_temp_celsius||-1)>0; text: 'Temp: '+(metrics.cpu_temp_celsius||0).toFixed(0)+'°C'; font.pixelSize: 14; color: theme.textSecondary }''')

widgets['PomodoroWidget.qml'] = card('Focus Timer', '⏱', '''property int minutes: 25; property int seconds: 0; property bool running: false
        Text { Layout.alignment: Qt.AlignHCenter; text: String(minutes).padStart(2,'0')+':'+String(seconds).padStart(2,'0'); font.pixelSize: 30; font.bold: true; font.family: 'monospace'; color: running ? theme.accent : theme.textPrimary }
        Text { Layout.alignment: Qt.AlignHCenter; text: running ? 'Running...' : 'Tap to start'; font.pixelSize: 11; color: theme.textSecondary }
        Timer { id: pomoTimer; interval: 1000; repeat: true; running: parent.parent.parent.running
            onTriggered: { if(parent.parent.parent.seconds>0) parent.parent.parent.seconds--; else if(parent.parent.parent.minutes>0) { parent.parent.parent.minutes--; parent.parent.parent.seconds=59; } else parent.parent.parent.running=false; } }
        MouseArea { anchors.fill: parent; onClicked: { parent.parent.parent.running = !parent.parent.parent.running; if(!parent.parent.parent.running) { parent.parent.parent.minutes=25; parent.parent.parent.seconds=0; } } }''')

widgets['ChecklistWidget.qml'] = card('Checklist', '✅', '''property var items: ['Review PRs', 'Update docs', 'Standup notes']; property var checked: [false,false,false]
        ListView { Layout.fillWidth: true; Layout.fillHeight: true; model: parent.items
            delegate: RowLayout { spacing: 6
                Rectangle { width: 16; height: 16; radius: 4; color: parent.parent.parent.checked[index] ? theme.accent : theme.cardBorder
                    Text { anchors.centerIn: parent; visible: parent.parent.parent.checked[index]; text: '✓'; font.pixelSize: 10; color: '#000' } }
                Text { text: modelData; font.pixelSize: 12; color: parent.parent.parent.checked[index] ? theme.textSecondary : theme.textPrimary }
                MouseArea { anchors.fill: parent; onClicked: { var c = parent.parent.parent.checked; c[index] = !c[index]; parent.parent.parent.checked = c; } }
            }
        }''')

widgets['HabitCalendarWidget.qml'] = card('Habit Calendar', '📅', '''property var days: {
            var d=new Date(); var m=d.getMonth(); var y=d.getFullYear();
            var first=new Date(y,m,1).getDay(); var total=new Date(y,m+1,0).getDate(); var a=[];
            for(var i=0;i<first;i++) a.push('');
            for(var i=1;i<=total;i++) a.push(i);
            return a;
        }
        GridLayout { Layout.fillWidth: true; columns: 7; columnSpacing: 2; rowSpacing: 2
            Repeater { model: ['S','M','T','W','T','F','S']
                Text { text: modelData; font.pixelSize: 9; color: theme.textSecondary; Layout.alignment: Qt.AlignHCenter }
            }
            Repeater { model: parent.parent.days
                Rectangle { width: 18; height: 18; radius: 4; color: modelData ? theme.cardBackground : 'transparent'; border.width: modelData?1:0; border.color: modelData?theme.cardBorder:'transparent'
                    Text { anchors.centerIn: parent; text: modelData||''; font.pixelSize: 9; color: (modelData===new Date().getDate())?theme.accent:theme.textSecondary }
                }
            }
        }''')

widgets['DailyQuoteWidget.qml'] = card('Daily Quote', '💬', '''property var quotes: ['The only way to do great work is to love what you do. - Steve Jobs','Stay hungry, stay foolish. - Steve Jobs','Code is like humor. When you have to explain it, it is bad. - Cory House','First, solve the problem. Then, write the code. - John Johnson','Simplicity is the soul of efficiency. - Austin Freeman']
        property string quote: quotes[Math.floor(Math.random()*quotes.length)]
        Text { Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: parent.parent.width*0.85; text: quote; font.pixelSize: 11; color: theme.textSecondary; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 4 }''')

widgets['PingWidget.qml'] = card('Ping Monitor', '📡', '''property var metrics: ({})
        Text { Layout.alignment: Qt.AlignHCenter; text: '● Online'; font.pixelSize: 16; font.bold: true; color: theme.success }
        Text { Layout.alignment: Qt.AlignHCenter; text: '8.8.8.8'; font.pixelSize: 12; color: theme.textSecondary }
        Rectangle { Layout.preferredWidth: parent.parent.width*0.8; Layout.preferredHeight: 24; Layout.alignment: Qt.AlignHCenter; radius: 4; color: theme.cardBorder
            Canvas { anchors.fill: parent; onPaint: { var ctx=getContext('2d'); ctx.strokeStyle=theme.accent; ctx.lineWidth=2; ctx.beginPath(); for(var i=0;i<30;i++){ var x=i*width/29; var y=height/2+Math.sin(i*0.6+Date.now()*0.001)*8; i===0?ctx.moveTo(x,y):ctx.lineTo(x,y); } ctx.stroke(); } }
            Timer { interval: 200; running: true; repeat: true; onTriggered: parent.children[0].requestPaint() }
        }
        Text { Layout.alignment: Qt.AlignHCenter; text: '~15ms'; font.pixelSize: 10; color: theme.textSecondary }''')

widgets['EndOfDayWidget.qml'] = card('End of Work', '🏁', '''property int hours: Math.max(0,17-new Date().getHours()); property int mins: Math.max(0,60-new Date().getMinutes())
        Text { Layout.alignment: Qt.AlignHCenter; text: String(hours).padStart(2,'0')+':'+String(mins).padStart(2,'0'); font.pixelSize: 28; font.bold: true; font.family: 'monospace'; color: theme.accent }
        Text { Layout.alignment: Qt.AlignHCenter; text: hours===0&&mins===0?'🎉 Done!':'until freedom'; font.pixelSize: 11; color: theme.textSecondary }''')

widgets['CountdownWidget.qml'] = card('Countdown', '⏳', '''property date target: new Date(2026,11,25)
        property var diff: { var d=target.getTime()-Date.now(); if(d<0) return {d:0,h:0,m:0,s:0}; return {d:Math.floor(d/86400000),h:Math.floor((d%86400000)/3600000),m:Math.floor((d%3600000)/60000),s:Math.floor((d%60000)/1000)} }
        Text { Layout.alignment: Qt.AlignHCenter; text: diff.d+'d '+diff.h+'h '+diff.m+'m'; font.pixelSize: 22; font.bold: true; font.family: 'monospace'; color: theme.accent }
        Text { Layout.alignment: Qt.AlignHCenter; text: 'Dec 25, 2026'; font.pixelSize: 11; color: theme.textSecondary }''')

widgets['MoonPhaseWidget.qml'] = card('Moon Phase', '🌙', '''property real phase: { var lp=2551443; var nd=new Date().getTime()/1000-947116800; var np=parseInt(nd/lp); var nm=Math.abs(nd-np*lp)/lp; return nm>0.5?2*(1-nm):2*nm; }
        Text { Layout.alignment: Qt.AlignHCenter; text: phase<0.02?'🌑':phase<0.25?'🌒':phase<0.48?'🌓':phase<0.52?'🌕':phase<0.75?'🌖':'🌗'; font.pixelSize: 36 }
        Text { Layout.alignment: Qt.AlignHCenter; text: (phase*100).toFixed(0)+'% illuminated'; font.pixelSize: 11; color: theme.textSecondary }''')

widgets['RssFeedWidget.qml'] = card('RSS Feed', '📰', '''property var items: ['Linux 6.12 released with new features','Qt 6.8 brings improved rendering','Xeneon Edge SDK updated to v2']
        ListView { Layout.fillWidth: true; Layout.fillHeight: true; model: parent.items
            delegate: Text { text: '• '+modelData; font.pixelSize: 11; color: theme.textSecondary; elide: Text.ElideRight; width: parent.width }
        }''')

widgets['SmokeClockWidget.qml'] = card('Analog Clock', '🕐', '''Canvas { Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 80; Layout.preferredHeight: 80
            onPaint: {
                var ctx=getContext('2d'); var w=width,h=height; var cx=w/2,cy=h/2,r=Math.min(w,h)/2-8;
                ctx.clearRect(0,0,w,h);
                ctx.strokeStyle=theme.cardBorder; ctx.lineWidth=2; ctx.beginPath(); ctx.arc(cx,cy,r,0,Math.PI*2); ctx.stroke();
                var d=new Date(); var hh=d.getHours()%12*30+d.getMinutes()*0.5; var mm=d.getMinutes()*6+d.getSeconds()*0.1; var ss=d.getSeconds()*6;
                ctx.strokeStyle=theme.textPrimary; ctx.lineWidth=2; ctx.beginPath(); ctx.moveTo(cx,cy); ctx.lineTo(cx+Math.sin(hh*Math.PI/180)*r*0.5,cy-Math.cos(hh*Math.PI/180)*r*0.5); ctx.stroke();
                ctx.strokeStyle=theme.accent; ctx.lineWidth=1.5; ctx.beginPath(); ctx.moveTo(cx,cy); ctx.lineTo(cx+Math.sin(mm*Math.PI/180)*r*0.7,cy-Math.cos(mm*Math.PI/180)*r*0.7); ctx.stroke();
                ctx.fillStyle=theme.error; ctx.beginPath(); ctx.arc(cx,cy,3,0,Math.PI*2); ctx.fill();
            }
            Timer { interval: 1000; running: true; repeat: true; onTriggered: parent.requestPaint() }
        }''')

widgets['RobexWidget.qml'] = card('Tourbillon', '⌚', '''Text { Layout.alignment: Qt.AlignHCenter; text: Qt.formatTime(new Date(),'HH:mm:ss'); font.pixelSize: 24; font.bold: true; font.family: 'monospace'; color: theme.accent }
        Text { Layout.alignment: Qt.AlignHCenter; text: Qt.formatDate(new Date(),'yyyy-MM-dd'); font.pixelSize: 10; color: theme.textSecondary }''')

widgets['CardOptimizerWidget.qml'] = card('Card Benefits', '💳', '''property var cards: [{name:'Amex Plat',perks:'$200 travel, $200 Uber'},{name:'Chase CSR',perks:'$300 travel, DoorDash'},{name:'Apple Card',perks:'3% Apple Pay'}]
        ListView { Layout.fillWidth: true; Layout.fillHeight: true; model: parent.cards
            delegate: Text { text: modelData.name+': '+modelData.perks; font.pixelSize: 10; color: theme.textSecondary; elide: Text.ElideRight; width: parent.width }
        }''')

# Sports widgets (simplified - using placeholder data)
sportsCard = lambda name,icon,team1,team2,score1,score2: card(name,icon,f'''Text {{ Layout.alignment: Qt.AlignHCenter; text: '{team1}  {score1} - {score2}  {team2}'; font.pixelSize: 20; font.bold: true; font.family: 'monospace'; color: theme.textPrimary }}
        Text {{ Layout.alignment: Qt.AlignHCenter; text: 'Q3 - 8:42'; font.pixelSize: 11; color: theme.accent }}
        Text {{ Layout.alignment: Qt.AlignHCenter; text: 'Standings: 1st in Division'; font.pixelSize: 10; color: theme.textSecondary }}''')

widgets['BaseballWidget.qml'] = sportsCard('Baseball','⚾','LAD','SFG','5','3')
widgets['BasketballWidget.qml'] = sportsCard('Basketball','🏀','LAL','BOS','108','102')
widgets['FootballWidget.qml'] = sportsCard('Football','🏈','KC','SF','24','17')
widgets['HockeyWidget.qml'] = sportsCard('Hockey','🏒','NYR','TOR','3','2')
widgets['MatchdayWidget.qml'] = sportsCard('Matchday','⚽','FCB','RMA','2','1')

widgets['F1Widget.qml'] = card('F1 Next Race','🏎️','''Text { Layout.alignment: Qt.AlignHCenter; text: 'Monaco GP'; font.pixelSize: 18; font.bold: true; color: theme.accent }
        Text { Layout.alignment: Qt.AlignHCenter; text: '5d 12h 34m'; font.pixelSize: 20; font.bold: true; font.family: 'monospace'; color: theme.textPrimary }
        Text { Layout.alignment: Qt.AlignHCenter; text: 'Circuit de Monaco'; font.pixelSize: 10; color: theme.textSecondary }''')

widgets['DiceRollerWidget.qml'] = card('Dice Roller','🎲','''property int lastRoll: 0; property int sides: 6
        Text { Layout.alignment: Qt.AlignHCenter; text: lastRoll>0?'🎲 '+lastRoll:'Tap to roll d'+sides; font.pixelSize: lastRoll>0?30:16; font.bold: true; color: theme.textPrimary }
        RowLayout { Layout.alignment: Qt.AlignHCenter; spacing: 4
            Repeater { model: [4,6,8,10,12,20]
                Rectangle { width: 24; height: 24; radius: 6; color: parent.parent.parent.sides===modelData?theme.accent:theme.cardBorder
                    Text { anchors.centerIn: parent; text: 'd'+modelData; font.pixelSize: 8; color: parent.parent.parent.sides===modelData?'#000':theme.textSecondary }
                    MouseArea { anchors.fill: parent; onClicked: { parent.parent.parent.sides=modelData; parent.parent.parent.lastRoll=0; } }
                }
            }
        }
        MouseArea { anchors.fill: parent; onClicked: { parent.parent.parent.lastRoll = Math.floor(Math.random()*parent.parent.parent.sides)+1; } }''')

widgets['LunchRouletteWidget.qml'] = card('Lunch Roulette','🍔','''property var options: ['🍕 Pizza','🍣 Sushi','🌮 Tacos','🍜 Ramen','🥗 Salad','🍔 Burger','🥙 Gyro','🍛 Curry']
        property string selected: ''
        Text { Layout.alignment: Qt.AlignHCenter; text: selected||'Spin for lunch!'; font.pixelSize: selected?20:14; font.bold: true; color: selected?theme.accent:theme.textSecondary }
        Button { Layout.alignment: Qt.AlignHCenter; text: '🎰 Spin'; flat: true; font.pixelSize: 12
            onClicked: { var i=Math.floor(Math.random()*parent.parent.parent.options.length); parent.parent.parent.selected=parent.parent.parent.options[i]; } }''')

widgets['BartWidget.qml'] = card('BART Times','🚇','''property var trains: [{dest:'SFO',min:'5'},{dest:'Daly City',min:'12'},{dest:'Richmond',min:'18'}]
        ListView { Layout.fillWidth: true; Layout.fillHeight: true; model: parent.trains
            delegate: RowLayout { spacing: 8
                Text { text: modelData.dest; font.pixelSize: 13; font.bold: true; color: theme.textPrimary; Layout.fillWidth: true }
                Text { text: modelData.min+' min'; font.pixelSize: 13; font.family: 'monospace'; color: parseInt(modelData.min)<10?theme.success:theme.textSecondary }
            }
        }''')

widgets['LondonTubeWidget.qml'] = card('Tube Times','🚂','''property var lines: [{line:'Central',dest:'Epping',min:'3'},{line:'District',dest:'Richmond',min:'7'},{line:'Piccadilly',dest:'Cockfosters',min:'11'}]
        ListView { Layout.fillWidth: true; Layout.fillHeight: true; model: parent.lines
            delegate: RowLayout { spacing: 8
                Rectangle { width: 8; height: 8; radius: 4; color: modelData.line==='Central'?'#DC241F':modelData.line==='District'?'#00782A':'#0019A8' }
                Text { text: modelData.dest; font.pixelSize: 12; color: theme.textPrimary; Layout.fillWidth: true }
                Text { text: modelData.min+' min'; font.pixelSize: 12; font.family: 'monospace'; color: parseInt(modelData.min)<5?theme.success:theme.textSecondary }
            }
        }''')

widgets['LiveCommuteWidget.qml'] = card('Commute','🚗','''Text { Layout.alignment: Qt.AlignHCenter; text: '🏠 → 🏢'; font.pixelSize: 16; color: theme.textPrimary }
        Text { Layout.alignment: Qt.AlignHCenter; text: '25 min'; font.pixelSize: 28; font.bold: true; font.family: 'monospace'; color: theme.accent }
        Text { Layout.alignment: Qt.AlignHCenter; text: 'Moderate traffic'; font.pixelSize: 10; color: theme.warning }''')

widgets['DoodlePadWidget.qml'] = card('Doodle Pad','✏️','''Canvas { Layout.fillWidth: true; Layout.fillHeight: true; id: doodleCanvas
            property var points: []
            onPaint: { var ctx=getContext('2d'); ctx.clearRect(0,0,width,height); if(points.length<2)return; ctx.strokeStyle=theme.accent; ctx.lineWidth=3; ctx.beginPath(); ctx.moveTo(points[0].x,points[0].y); for(var i=1;i<points.length;i++)ctx.lineTo(points[i].x,points[i].y); ctx.stroke(); }
            MouseArea { anchors.fill: parent; onPressed: parent.points=[]; onPositionChanged: function(mouse){ parent.points.push({x:mouse.x,y:mouse.y}); parent.requestPaint(); } }
        }''')

widgets['LossTrackerWidget.qml'] = card('Win/Loss','📈','''property int wins: 42; property int losses: 18
        RowLayout { Layout.alignment: Qt.AlignHCenter; spacing: 16
            ColumnLayout { spacing: 2
                Text { Layout.alignment: Qt.AlignHCenter; text: 'W'; font.pixelSize: 11; color: theme.success }
                Text { Layout.alignment: Qt.AlignHCenter; text: wins; font.pixelSize: 24; font.bold: true; font.family: 'monospace'; color: theme.success }
            }
            Rectangle { width: 1; height: 40; color: theme.cardBorder }
            ColumnLayout { spacing: 2
                Text { Layout.alignment: Qt.AlignHCenter; text: 'L'; font.pixelSize: 11; color: theme.error }
                Text { Layout.alignment: Qt.AlignHCenter; text: losses; font.pixelSize: 24; font.bold: true; font.family: 'monospace'; color: theme.error }
            }
        }
        Text { Layout.alignment: Qt.AlignHCenter; text: (wins/(wins+losses)*100).toFixed(1)+'% win rate'; font.pixelSize: 10; color: theme.textSecondary }''')

widgets['ScrollitWidget.qml'] = card('Image Feed','🖼️','''Text { Layout.alignment: Qt.AlignHCenter; text: '🖼️  r/pics'; font.pixelSize: 14; font.bold: true; color: theme.textPrimary }
        Text { Layout.alignment: Qt.AlignHCenter; text: 'Beautiful sunset over Golden Gate'; font.pixelSize: 11; color: theme.textSecondary }
        Rectangle { Layout.preferredWidth: parent.parent.width*0.8; Layout.preferredHeight: 50; Layout.alignment: Qt.AlignHCenter; radius: 8; color: Qt.rgba(1,0.6,0.2,0.3)
            Text { anchors.centerIn: parent; text: '🖼️'; font.pixelSize: 30 }
        }
        Text { Layout.alignment: Qt.AlignHCenter; text: '⬅️ Swipe for more'; font.pixelSize: 9; color: theme.textSecondary }''')

widgets['ReaditWidget.qml'] = card('Reddit Feed','📱','''property var posts: [{title:'r/linux: Kernel 6.12 released',score:'1.2k'},{title:'r/programming: New Rust pattern',score:'892'},{title:'r/unixporn: My desktop setup',score:'3.4k'}]
        ListView { Layout.fillWidth: true; Layout.fillHeight: true; model: parent.posts
            delegate: RowLayout { spacing: 6
                Text { text: '⬆'+modelData.score; font.pixelSize: 9; color: theme.accent; Layout.preferredWidth: 40 }
                Text { text: modelData.title; font.pixelSize: 11; color: theme.textSecondary; elide: Text.ElideRight; Layout.fillWidth: true }
            }
        }''')

widgets['ViewStatsWidget.qml'] = card('System Stats','📊','''property var metrics: ({})
        Text { Layout.alignment: Qt.AlignHCenter; text: '📈 '+((metrics.cpu_usage_percent||0).toFixed(0))+'% CPU'; font.pixelSize: 13; font.family: 'monospace'; color: theme.textPrimary }
        Text { Layout.alignment: Qt.AlignHCenter; text: '🧠 '+((metrics.ram_usage_percent||0).toFixed(0))+'% RAM'; font.pixelSize: 13; font.family: 'monospace'; color: theme.textPrimary }
        Text { Layout.alignment: Qt.AlignHCenter; text: '🖥 '+(metrics.cpu_core_count||1)+' cores'; font.pixelSize: 13; font.family: 'monospace'; color: theme.textSecondary }
        Text { Layout.alignment: Qt.AlignHCenter; visible: (metrics.cpu_temp_celsius||-1)>0; text: '🌡 '+(metrics.cpu_temp_celsius||0).toFixed(0)+'°C'; font.pixelSize: 12; color: theme.warning }''')

created = skipped = novel = 0
for fname, content in widgets.items():
    path = os.path.join(base, fname)
    exists = os.path.exists(path)
    if exists and not FORCE:
        print(f'SKIP (exists, hand-maintained): {fname}')
        skipped += 1
        continue
    if not exists and not FORCE:
        # A name in this scaffolding that no longer exists in the repo. Of the
        # ~30 names here, only 3 still match a real widget; the rest are ghosts
        # of an early draft. Emitting them without --force just litters 27
        # untracked stub files (it did, on 2026-07-17). A genuinely new widget
        # is added by hand, not resurrected from this list.
        novel += 1
        continue
    with open(path, 'w') as f:
        f.write(content.strip() + '\n')
    print(f'{"OVERWROTE" if exists else "Created"}: {fname}')
    created += 1
if novel and not FORCE:
    print(f'{novel} scaffolded name(s) not in the repo were NOT created '
          f'(stale draft; use --force only if you truly want them).')

print(f'\nWrote {created}, skipped {skipped} existing.')
if skipped and not FORCE:
    print('Existing files were left untouched. Pass --force to overwrite them -')
    print('but read this script\'s header first: the repo widgets have diverged far')
    print('past this scaffolding, and --force replaces them with stubs.')

