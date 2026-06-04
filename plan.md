Egy natív MacOS applikáció fejlesztése a cél.
Általános funkciója hangfájlok készítése és szerkesztése.
Az app átlátható és egyszerűen kezelhető, de modern felhasználói felülettel rendelkezzen.
Az app egy főablakkal nyílik meg, ezen belül, modálisan nyílnak meg az al-ablakok, amikben egy-egy hangfájl hanghullám képe látható. Egyszerre több hangfájl lehet kezelni.
Ezeket az al-ablakokat szabadon lehet mozgatni, de legyen néhány előre beépített lehetőség is a rendezésükre.
Ha megnyílik egy hangfájl, akkor a saját modális ablaka legyen a főablakhoz mértem a legszélesebb, és a teljes fájl hanghullám képe legyen benne, úgy legyen beállítva a zoom-olás.
A betöltött hangállományokat (mp3, wav, aac, flac, ogg) a felületen hanghullám formámban láttatja.
A hanghullámok részeit ki lehet jelölni, így lehet manipulálni.
Egy adott hangfájlt a hanghullám képén keresztül lehet manipulálni: lejátszani, kivágni belőle, beilleszteni kivágott részeket.
A Hanghullámba be lehet nagyítani, és a saját ablakán belül, alsó részen egy ms pontos idősáv legyen.
Lehessen létrehozni is hangfájlokat, ekkor egy üres al-ablak jelenjen meg, amibe más hangfájlokból lehet összemásolni az adatot.
Minden hangfájlnak legyen egy kurzora, függőleges vonal, az mutatja hol jár a lejátszás, melyik része van kijelölve (ez legyen más színű), és mutatja meg, honnan történik a beillesztés.
Egy hangfájlt el is lehessen menteni, ahol az app megkérdi, hogy a kezelt formátumok közül melyikben legyen elmentve a hangadat.

kezelőfelület:
Az app egy nyitó képernyővel indít. Ez egy kisméretű (800x600 pixel) ablak, amin a voxbarber_logo.png kép van, az alján egy START gomb, ami bezárja ezt az ablakot és a főképernyőre navigál. Az ablak nem méretezhető, de mozgatható, a kép az ablakhoz van igazítva.
Az app főképernyője egy 1200x800 pixeles ablak, amennyiben az OS ezt nem engedi, akkor a legnagyobb mérteben, ami lehetséges. A főképernyő átméretezhető, mozgatható.
Az app menüje: 
Fájl menü » Új hangfájl, Hangfájl megnyitása, Hangfájl mentése, Kilépés
Szerkesztés menü » Másol, Kivág, Beilleszt, Töröl
Lejátszás menü » Lejátszás az elejétől, Kijelölt rész lejátszása, Lejátszás a kijelölt ponttól
Nézet menü » Vízszintes ablak elrendezés, Négyzetes ablak elrendezés, Lapozott ablak elrendezés, Ablak elrendezés mentése, Ablak elrendezés betöltése
Segítség menü » VoxBarber használata, Szerzői jogok
A "szerkesztés" és a "lejátszás" menü elemei akkor aktívak, ha relevánsak. Tehát, ha nincs kiválasztva hangfájl, akkor nem lehet lejátszani. Ha nincs kijelölve semmi egy hangfájlban, akkor nem lehet szerkeszteni sem, stb
A főképernyő üres. Kezdetben nincs tartalma.
Az "új hangfájl" vagy a "hangfájl megnyitása" funkció hatására egy gyerek ablak nyílik meg. A gyerek ablakot nem lehet kimozgatni a főablakból, de átméretezhető és mozgatható.
A gyerek ablakoknak van felső ikon/menüsora. Ott PLAY, PAUSE és STOP gombok vannak egy csoportban. Egy másik csoportban COPY, CUT és PASTE gombok vannak. A harmadikban egy "követés" kétállású gomb, valamint zoom in és zoom out, illetve egy balra és egy jobbra gomb. A negyedik csoport egy infó gomb, ami kinyit egy kicsi információs ablakot, ahol az adott fájlról vannak adatok: név, elérési útvonal, fájltípus, a zene hossza, tömörítési ráta és ha vannak a fájlban akkor egyéb infók, pl. zeneszám címe, előadó, kiadás éve, stb.
Ha egy hangfájl-ablak aktív, mert az szól, vagy az van szerkesztve, akkor annak a kerete, fejléce legyen élénkebb, mint a többié.

hangmotor:
Az app képes legyen kezelni WAV, MP3, AAC, FLAC és OGG típusú fájlokat is. Betölteni, lejátszani, kimenteni és szerkeszteni kell tudni ezeket.
Egy sarokpont az új fájl létrehozása. itt arról van szó, hogy lehessen új hangfájl létrehozni úgy, hogy más, már megnyitott hangfájlokból összemásolja őket a felhasználó. 
Ha bezáródik egy hangfájl gyerek-ablaka, és szólt a lejátszás, akkor álljon le. Ha abból a hangfájlból van valami a vágólapon, akkor kérdezze meg, hogy megtartsa-e az app, vagy eldobható.
Minden gyerek-ablak a saját hangfájlját játsza, és ha aktívvá teszi a felhasználó az ablakot, és lejátszást nyom, akkor ahonnan folytatódjon a lejátszás, ahonnan előzőleg abbahagyta.
Minden gyerek-ablak jobb felső sarkában van egy stopper, ami mutatja, hogy a lejátszás hol tart a hangfájlban, HH:MM:SS.mmmm formában, ahol H - óra, M - perc, S - másodperc, mmmm - ezredmásodprec (4 digit)

hanghullám:
amikor egy gyerek-ablakba betöltődik egy hangfájl, akkor az ablak méretében legyenek láthatóak a hanghullámok. Ezt lehessen zoomolni ki és be. Illetve a hanghullám képet a fogd-és-vidd technikával balra-jobbra csúsztatható legyen az ablakon belül az időskálának megfelelően.
Balra-jobbra gombok a hanghullámot mozgatják a megfelelő irányba a bezoomolt hangfájlrészlet hosszának negyedével.
Az ablak alján lehessen látni egy időskálát, a zoomolásnak megfelelő sűrűségben. Ergó ha ki van zoomlova, akkor még a másodperc is sok lehet, de ha rá van közelítve akkor az millisec is kirajzolható.
Lejátszáskor egy élénk színű függőleges vonal mutatja, hol jár a lejátszás.