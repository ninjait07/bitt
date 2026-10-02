# BITT — โปรแกรมโหลด BitTorrent สำหรับ Mac

แอป macOS แบบ native (SwiftUI) ที่ **ทำงานอยู่บน menu bar**
เอนจิน BitTorrent เขียนด้วย Swift ล้วน คอมไพล์รวมอยู่ในไบนารีเดียว
ติดตั้งแล้วที่ **`/Applications/BITT.app`**

ไบนารีเดียว ~3.4 MB ไม่ต้องพึ่ง Python ของเครื่อง ไม่ต้องติดตั้งอะไรเพิ่มเลย

**โหลดไฟล์ติดตั้งได้ที่ [Releases](https://github.com/ninjait07/bitt/releases/latest)** —
ดับเบิลคลิกแล้วลาก BITT ไปใส่ Applications เซ็นและ notarize จาก Apple แล้ว เปิดได้เลยไม่มีคำเตือน

## อยู่บน menu bar

เปิดแอปแล้วจะเห็นไอคอนหกเหลี่ยมมีลูกศรลงที่มุมขวาบนของจอ — **ไม่ขึ้นใน Dock**
คลิกที่ไอคอนเพื่อเปิดแผงควบคุม ซึ่งทำได้เกือบทุกอย่าง:

- ความเร็วรวมขึ้น–ลง และจำนวนที่กำลังทำงาน
- รายการ torrent แบบย่อ พร้อมแถบความคืบหน้าและปุ่มหยุด/เล่นต่อรายตัว
  (คลิกที่ชื่อเพื่อเปิดใน Finder)
- Add Torrent File… / Add Magnet from Clipboard
- Pause All / Resume All
- Open Download Folder
- Open Main Window / Settings / Quit

ขณะกำลังโหลด ไอคอนบน menu bar จะแสดงความเร็วดาวน์โหลดต่อท้ายด้วย

## ขอบเขตของโปรเจกต์ — ตั้งใจทำแค่นี้

BITT ทำมาเพื่อ **คนที่มีเว็บ torrent ใช้อยู่แล้ว** ไม่ได้ตั้งใจเป็นไคลเอนต์ครบเครื่อง
ขอบเขตนี้เป็นการตัดสินใจ ไม่ใช่ของที่ยังทำไม่เสร็จ

**ทำงานกับ:** torrent และ magnet link ที่มี tracker ติดมาด้วย ซึ่งก็คือเกือบทั้งหมด
ที่โหลดมาจากเว็บ — private tracker จะแนบ announce URL พร้อม passkey มาเสมอ
ส่วนเว็บสาธารณะก็แนบ tracker มาเป็นพรวนอยู่แล้ว

**ไม่ทำ: DHT (BEP 5) และ PEX (BEP 11)** ด้วยเหตุผลสามข้อ

1. **private tracker ห้ามใช้ทั้งคู่** torrent จากเว็บพวกนี้มี flag `private`
   เปิด DHT/PEX แล้วเสี่ยงโดนแบนบัญชี — กับผู้ใช้กลุ่มเป้าหมาย มันจึงไม่ใช่แค่
   ไม่จำเป็น แต่เป็นโทษ
2. **magnet จากเว็บมี tracker อยู่แล้ว** DHT เลยไม่ได้ช่วยอะไรในทางปฏิบัติ
3. **DHT ขัดกับเป้าหมาย "เบา"** โหนด DHT ต้องรับ UDP จากทั่วโลกตลอดเวลาแม้ไม่ได้
   โหลดอะไร กินเน็ตและ CPU ตลอด และเอา IP เราไปอยู่ในเครือข่ายสาธารณะ
   ตัวโค้ดเองก็ราว 800–1,200 บรรทัด คือ +25% ของเอนจินทั้งตัว

**ผลที่ตามมา:** magnet เปล่า ๆ ที่มีแต่ `xt=urn:btih:...` ไม่มี `&tr=` จะใช้ไม่ได้
แอปจะ**เตือนให้เห็นตั้งแต่ตอนกดเพิ่ม** ไม่ปล่อยให้ค้างที่ 0% โดยไม่รู้สาเหตุ

ถ้าวันหนึ่งเปลี่ยนใจจะแจกสาธารณะ ลำดับที่ควรทำคือ
**บังคับใช้ flag `private` ให้จริงจัง → PEX → DHT**
(ตอนนี้ flag นี้ถูกอ่านและแสดงผล แต่ยังไม่ได้บังคับอะไร ซึ่งถูกต้องเพราะยังไม่มี
อะไรให้ปิด — นาทีที่เพิ่ม DHT/PEX ตัวบังคับนี้กลายเป็นของบังคับทันที)

## เพิ่ม torrent

เพิ่มทางไหนก็ตาม **แอปจะเด้งขึ้นมาถามก่อน** ว่าจะ Download Now, Add Paused หรือ Cancel
พร้อมบอกชื่อ ขนาด จำนวนไฟล์ และเปลี่ยนโฟลเดอร์ปลายทางได้ในหน้าต่างเดียวกัน
(ปิดได้ที่ Settings → Downloads)

- ไอคอน menu bar → **Add Torrent File…**
- คัดลอก magnet link แล้ว → **Add Magnet from Clipboard** (หรือ ⇧⌘V)
- **คลิก magnet link** ในเบราว์เซอร์ได้เลย
- **ดับเบิลคลิกไฟล์ `.torrent`** ใน Finder (ครั้งแรกคลิกขวา → Open With → BITT)
- **ลากไฟล์ `.torrent`** มาวางบนหน้าต่างหลัก

## โฟลเดอร์ดาวน์โหลด

อยู่ที่ **แถบล่างสุดของหน้าต่างหลัก** — บอกว่าตอนนี้เซฟลงที่ไหน พร้อมปุ่ม **Change…**,
ปุ่มเปิดโฟลเดอร์ใน Finder และช่อง **Ask each time**

ติ๊ก Ask each time แล้วมันจะถามโฟลเดอร์ทุกครั้งที่เพิ่ม torrent ใหม่ —
ใช้ได้กับทุกทางที่เพิ่ม รวมถึงตอนคลิก magnet link จากเบราว์เซอร์

เปลี่ยนจากที่อื่นก็ได้: เมนู **Transfers → Change Download Folder…** หรือ **Settings (⌘,)**

### ปุ่มลัด

| คีย์ | ทำอะไร |
|---|---|
| ⌘O | เปิดไฟล์ `.torrent` |
| ⇧⌘V | เพิ่ม magnet link จากคลิปบอร์ด |
| ⌘I | เปิด/ปิดแถบรายละเอียดด้านล่าง |
| ⌘1 | เปิดหน้าต่างหลัก |
| ⌘. | หยุดทุกตัวชั่วคราว |
| ⇧⌘. | เล่นต่อทุกตัว |
| ⇧⌘D | เปิดโฟลเดอร์ดาวน์โหลด |
| ⌘, | ตั้งค่า |

### หน้าต่างหลัก

เปิดจากแผง menu bar → *Open Main Window* หรือ ⌘1 (ตอนเปิดหน้าต่าง ไอคอนใน Dock
จะโผล่มาชั่วคราว แล้วหายไปเองเมื่อปิดหน้าต่าง)

- แถบซ้ายกรองตามสถานะ: All / Downloading / Seeding / Paused / Finished พร้อมตัวเลข
  และสรุปความเร็วรวมกับพอร์ตที่เปิดอยู่ด้านล่าง
- รายการกลางแสดงแถบความคืบหน้า, ขนาด, ความเร็วขึ้น–ลง, จำนวน peer และเวลาที่เหลือ
- **Liquid Glass** บนพื้นผิวที่ลอยอยู่ (หน้าต่างถามตอนเพิ่ม, แผง menu bar, แถบล่าง)
  เมื่อรันบน macOS 26 ขึ้นไป เวอร์ชันเก่ากว่ากลับไปใช้วัสดุเดิมเอง
- **Ratio และยอดแชร์สะสม** ต่อท้ายแถวของ torrent ที่เคยอัปโหลด นับข้ามการเปิดปิดแอป
- **จุดบอกว่าต่อเข้าได้ไหม** ที่มุมซ้ายล่าง พร้อมผลการขอเปิดพอร์ตจากเราเตอร์
- **สีบอกสถานะ**: น้ำเงิน = กำลังโหลด, เขียว = แจกจ่าย, ส้ม = หยุด, เขียวอมฟ้า = เสร็จแล้วไม่แจกต่อ,
  ม่วง = กำลังหา metadata — ใช้ทั้งไอคอน แถบความคืบหน้า เปอร์เซ็นต์ และตัวกรองในแถบซ้าย
- toolbar เหลือ 4 ปุ่ม: **+** (กดค้างเลือกไฟล์/magnet), **▶/⏸**, **🗑**, **▣** เปิดปิดแถบรายละเอียด
  ส่วน Show in Finder กับ Copy Magnet Link ย้ายไปคลิกขวา และดับเบิลคลิกแถวเพื่อเปิดใน Finder
- **แถบโฟลเดอร์ดาวน์โหลดอยู่ล่างสุด** เห็นตลอดว่าเซฟลงที่ไหน เปลี่ยนได้ทันที
- **แถบรายละเอียดซ่อนไว้เป็นค่าเริ่มต้น** เรียกขึ้นมาด้วย ⌘I หรือปุ่มขวาสุดของ toolbar
  มี 4 แท็บ: **Files** (ความคืบหน้าแต่ละไฟล์), **Peers** (ใครเชื่อมอยู่ ใช้โปรแกรมอะไร),
  **Trackers** (ผลการ announce ล่าสุด), **Log**
- คลิกขวาที่รายการ: หยุด/เล่นต่อ, เปิดใน Finder, คัดลอก magnet link, ลบ

### เรื่องที่ควรรู้

- **ปิดหน้าต่างไม่ใช่การออกจากโปรแกรม** แอปยังอยู่บน menu bar และ seed ต่อให้ —
  สั่งออกจริงด้วย ⌘Q (แอปจะแจ้ง tracker และเขียนข้อมูลลงดิสก์ให้เรียบร้อยก่อนปิด)
- อยากให้มีไอคอนใน Dock ตลอดเวลา เปิด *Show BITT in the Dock* ใน Settings
- **หยุดกลางคันได้** ปิดแอปหรือปิดเครื่องแล้วเปิดใหม่ มันจะตรวจ SHA-1 ไฟล์เดิมแล้วโหลดต่อจากจุดที่ค้าง
  ไม่ต้องเริ่มใหม่ ไม่มีไฟล์สถานะให้เสียหาย เพราะใช้ข้อมูลจริงบนดิสก์เป็นตัวตัดสิน
- ครั้งแรกที่เปิด macOS อาจถามเรื่อง**อนุญาตการเชื่อมต่อขาเข้า** ให้กด Allow (ไม่กดก็ยังโหลดได้
  แต่คนอื่นจะต่อเข้ามาหาเราไม่ได้)
- ข้อมูลสถานะเก็บที่ `~/Library/Application Support/BITT/` (มี `app.log` ไว้ดูเวลามีปัญหา)

### ข้อจำกัด

- **ไม่มี DHT และ PEX** — เป็นการตัดสินใจ ไม่ใช่ของค้าง เหตุผลอยู่ที่หัวข้อ
  [ขอบเขตของโปรเจกต์](#ขอบเขตของโปรเจกต์--ตั้งใจทำแค่นี้) ด้านบน
- ไม่มีการเข้ารหัสการเชื่อมต่อ (MSE/PE) — ISP บางเจ้าอาจ throttle
- ไม่รองรับ BitTorrent v2 (magnet แบบ `btmh:`)
- แอปเซ็นแบบ ad-hoc (ใช้ในเครื่องนี้) ถ้าก๊อปไปเครื่องอื่นผ่านอินเทอร์เน็ต Gatekeeper จะเตือน
  ให้คลิกขวา → Open ครั้งแรก

## สร้างใหม่ / แก้ไขแล้วติดตั้งทับ

```bash
cd <โฟลเดอร์โปรเจกต์>
bash macapp/build.sh --install --out <โฟลเดอร์ที่ต้องการ>   # ติดตั้ง + ทำ dmg ไว้ที่นั่น
bash macapp/build.sh --install --dmg   # คอมไพล์ + ติดตั้ง + ทำไฟล์ dist/BITT-1.0.dmg
bash macapp/build.sh --install         # ติดตั้งอย่างเดียว
bash macapp/build.sh --dmg             # ทำไฟล์ติดตั้งอย่างเดียว
bash macapp/build.sh                   # สร้างไว้ที่ macapp/build/BITT.app เฉย ๆ
```

ใช้เวลาประมาณ 20 วินาที ต้องมี Xcode Command Line Tools (มีอยู่แล้วในเครื่องนี้)

## ใช้ผ่าน Terminal ก็ได้

เอนจินตัวเดียวกันมี CLI ให้ด้วย:

```bash
./torrentdl หนัง.torrent -o ~/Downloads        # ดาวน์โหลด
./torrentdl "magnet:?xt=urn:btih:..." --seed    # จาก magnet link
./torrentdl info หนัง.torrent                   # ดูข้างในโดยไม่โหลด
./torrentdl seed หนัง.torrent -o ~/Movies      # แจกจ่ายไฟล์ที่มีอยู่
./torrentdl create ~/Movies/งานแต่ง \           # สร้าง .torrent ของตัวเอง
    --tracker udp://tracker.opentrackr.org:1337/announce
```

ตัวเลือกอื่น ๆ ดูที่ `./torrentdl --help`
อยากเรียกจากที่ไหนก็ได้: `ln -s "$PWD/torrentdl" /usr/local/bin/torrentdl`

## โครงสร้างโปรเจกต์

เอนจินมีสองชุดที่พูดโปรโตคอลเดียวกัน: **Swift** คือของที่แอปใช้จริง ส่วน **Python**
เก็บไว้เป็นตัวอ้างอิงกับ CLI และชุดเทสต์ของ Swift ใช้เทียบผลกับมันทุกครั้งที่รัน

```
Bit Torrent/
├── macapp/Sources/Engine/    เอนจิน BitTorrent ภาษา Swift (ตัวที่แอปใช้)
│   ├── Bencode.swift             เข้ารหัส/ถอดรหัสแบบรักษาไบต์เป๊ะ
│   ├── Metainfo.swift            อ่าน .torrent และ magnet, กันชื่อไฟล์หลุดโฟลเดอร์
│   ├── PeerProtocol.swift        รูปแบบข้อความบนสาย + extension protocol
│   ├── Pieces.swift              เลือก piece แบบ rarest-first, ตรวจ SHA-1
│   ├── Storage.swift             แปลง offset เป็นไฟล์จริง, resume
│   ├── Tracker.swift             announce แบบ HTTP และ UDP พร้อม backoff
│   ├── TCPConnection.swift       สตรีม TCP บน Network.framework
│   ├── PeerConnection.swift      สถานะ peer หนึ่งราย (actor)
│   ├── PeerListener.swift        พอร์ตขาเข้าพอร์ตเดียวแยกงานตาม info-hash
│   ├── TorrentSession.swift      ตัวประสานงานของ torrent หนึ่งตัว (actor)
│   └── TorrentManager.swift      หลาย torrent + จำรายการข้ามการเปิดปิด
├── macapp/EngineTests/       ชุดเทสต์ของเอนจิน Swift (111 เทสต์)
├── torrentdl                 คำสั่ง CLI (ใช้เอนจิน Python)
├── pytorrent/                เอนจิน BitTorrent ภาษา Python — ตัวอ้างอิงและ CLI
│   ├── bencode.py            เข้ารหัส/ถอดรหัส bencode แบบรักษาไบต์เป๊ะ
│   ├── metainfo.py           อ่าน .torrent และ magnet, กันชื่อไฟล์หลุดนอกโฟลเดอร์
│   ├── protocol.py           รูปแบบข้อความบนสาย + extension protocol
│   ├── peer.py               สถานะ peer หนึ่งราย: choke/interest, คิวขอข้อมูล, อัปโหลด
│   ├── pieces.py             เลือก piece/block แบบ rarest-first, ตรวจ SHA-1
│   ├── storage.py            แปลง offset เป็นไฟล์จริง, resume, ตรวจไฟล์เดิม
│   ├── tracker.py            announce แบบ HTTP และ UDP พร้อม backoff
│   ├── listener.py           พอร์ตขาเข้าพอร์ตเดียวที่แยกงานตาม info-hash
│   ├── session.py            ตัวประสานงานของ torrent หนึ่งตัว
│   ├── daemon.py             จัดการหลาย torrent + โปรโตคอล JSON ที่แอปคุยด้วย
│   ├── create.py             สร้างไฟล์ .torrent
│   └── cli.py                คำสั่งและหน้าจอ terminal
├── macapp/                   แอป macOS
│   ├── Sources/
│   │   ├── BittApp.swift         จุดเริ่ม: MenuBarExtra + Settings + AppDelegate
│   │   ├── Theme.swift           สีประจำสถานะ (ที่เดียวสำหรับทั้งแอป)
│   │   ├── LogoImage.swift       โลโก้สำหรับใช้ในหน้าจอ
│   │   ├── MenuBarPanel.swift    แผงที่ดรอปลงมาจากไอคอน menu bar
│   │   ├── BittMark.swift        รูปทรงโลโก้ (ใช้ทั้งไอคอนแอปและไอคอน menu bar)
│   │   ├── StatusIcon.swift      ไอคอน menu bar แบบ template
│   │   ├── WindowManager.swift   เปิดหน้าต่างหลักตามสั่ง + สลับโหมด Dock
│   │   ├── Commands.swift        เมนูบนแถบเมนู
│   │   ├── MainView.swift        หน้าต่างหลัก
│   │   ├── DetailPane.swift      แถบ Files / Peers / Trackers / Log
│   │   ├── SettingsView.swift    หน้าตั้งค่า
│   │   ├── Engine.swift          คุยกับเอนจิน Python ผ่าน JSON
│   │   └── Prefs.swift           ค่าตั้งฝั่งแอป + เส้นทางการเพิ่ม torrent
│   ├── Tools/makeicon.swift  วาดไอคอนแอปด้วย CoreGraphics
│   ├── build.sh              คอมไพล์ + ประกอบ .app + ติดตั้ง
│   └── HELP.md               เมนู Help ในแอป
└── tests/                    ชุดทดสอบ
```

แอปคุยกับเอนจินผ่าน JSON บรรทัดละคำสั่งทาง stdin/stdout เอนจินส่งสถานะทุก 1 วินาที
ทุก torrent ใช้พอร์ตขาเข้าร่วมกันพอร์ตเดียว แล้วแยกงานตาม info-hash ในขั้นตอน handshake

## รองรับตามมาตรฐาน

- BEP 3 — โปรโตคอลหลัก, bencode, ไฟล์เดี่ยวและหลายไฟล์
- BEP 9 + BEP 10 — magnet link (ดึง metadata จาก peer ผ่าน `ut_metadata`)
- BEP 15 — UDP tracker
- BEP 23 — compact peer list รวม IPv6 (`peers6`)
- เลือก piece แบบ rarest-first + endgame mode, choke/unchoke แบบ tit-for-tat + optimistic unchoke
- NAT-PMP (BEP ไม่เกี่ยว, RFC 6886) และ UPnP IGD สำหรับขอให้เราเตอร์เปิดพอร์ตให้
- จำกัดความเร็วขึ้น–ลงด้วย token bucket ที่ใช้ร่วมกันทุก torrent
- ตรวจ SHA-1 ทุก piece ก่อนเขียนลงดิสก์ ข้อมูลเสียจะถูกโหลดใหม่อัตโนมัติ

## การทดสอบ

```bash
bash macapp/run-tests.sh       # 120 เทสต์ — เอนจิน Swift ตัวที่แอปใช้จริง
python3 tests/test_units.py    # 28 เทสต์ — เอนจิน Python
python3 tests/test_swarm.py    # 6 เทสต์ — รับส่งจริงผ่าน socket บน loopback
```

`run-tests.sh` สร้าง fixture ด้วยเอนจิน Python ก่อน แล้วให้ Swift เทียบกับมัน ครอบคลุม:

- **ไบต์บนสายตรงกันทุกเฟรม** — handshake, request, piece, bitfield, ut_metadata,
  extended handshake และการ percent-encode ของ announce
- **ค่าที่อ่านจาก .torrent ตรงกันทุกตัว** รวมถึง hash ของทุก piece
- **โอนไฟล์จริงผ่าน socket**: Swift ↔ Swift ผ่าน magnet link (ต้องดึง metadata จาก peer)
- **Swift โหลดจากเอนจิน Python ได้** ซึ่งเป็นตัวที่พิสูจน์แล้วว่าคุยกับ qBittorrent,
  Transmission และ Deluge ได้

`test_swarm.py` สร้าง session จริงหลายตัวคุยกันผ่าน 127.0.0.1 ครอบคลุม: โอนไฟล์จาก `.torrent`,
โอนผ่าน magnet (ต้องดึง metadata จาก peer), resume จากไฟล์ที่เสียบางส่วน,
leecher ส่งต่อข้อมูลให้ leecher อีกตัว และปฏิเสธ peer ที่ info-hash ไม่ตรง

ฝั่งแอปทดสอบแล้ว: เพิ่มผ่าน magnet link, เพิ่มไฟล์ `.torrent` จาก Finder, คืนรายการหลังเปิดใหม่,
เมนูอยู่ครบหลัง SwiftUI สร้าง scene ใหม่, และไอคอน Dock หายเมื่อปิดหน้าต่าง/กลับมาเมื่อเปิด

ทดสอบกับ swarm จริงแล้วทั้งสองเอนจิน: โหลด Debian 13.7 netinst ISO (756 MiB) จนครบ
ผ่าน tracker ของ Debian ต่อกับ peer จริง (qBittorrent, Transmission, Deluge, rqbit)
ที่ 9–11 MiB/s โดย **SHA256 ของไฟล์ที่ได้ตรงกับที่ Debian ประกาศทุกไบต์** และ hash ผิด 0 ครั้ง

## หมายเหตุ

โปรแกรมนี้โหลดอะไรก็ตามที่เราป้อน torrent ให้ — การเลือกว่าจะโหลดอะไรเป็นความรับผิดชอบของผู้ใช้เอง
