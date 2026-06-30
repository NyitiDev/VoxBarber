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
Fájl menü » Új hangfájl, Hangfájl megnyitása, Hangfájl mentése, Jelölőpontok betöltése, Kilépés
Szerkesztés menü » Másol, Kivág, Beilleszt, Összemos, Új jelölőpont, Jelölőpontok listája
Lejátszás menü » Lejátszás az elejétől, Kijelölt rész lejátszása, Lejátszás a kijelölt ponttól, Lejátszás követése ki/be.
Nézet menü » Vízszintes ablak elrendezés, Négyzetes ablak elrendezés, Lapozott ablak elrendezés, Ablak elrendezés mentése, Ablak elrendezés betöltése. Alatta, külön Színek beállítása.
Segítség menü » VoxBarber használata, Szerzői jogok
A "szerkesztés" és a "lejátszás" menü elemei akkor aktívak, ha relevánsak. Tehát, ha nincs kiválasztva hangfájl, akkor nem lehet lejátszani. Ha nincs kijelölve semmi egy hangfájlban, akkor nem lehet szerkeszteni sem, stb

A főképernyő üres. Kezdetben nincs tartalma.
A menüben lévő "színek beállítása" funkció egy kisebb ablakot nyit meg, ahol fel vannak sorolva az app használatban lévő színei: háttérszín, gombok színe, hanghullám színe, jelölő vonal színe, kijelölés színe, feliratok színe. Mindegyik mellett színválasztó lehetőség. Alul mentés, betöltés, Bezárás gombok, amik értelemszerűen működnek. A kimentendő fájl kiterjesztése, VBC, de egy JSON. Az app a beállított színséma szerint rajzolja ki a felsorolt elemeket.

Gyerekablakok hangfájloknak:
Az "új hangfájl" vagy a "hangfájl megnyitása" funkció hatására egy gyerek ablak nyílik meg. A gyerek ablakot nem lehet kimozgatni a főablakból, de átméretezhető és mozgatható. A bal felső sarkában van piros, bezáró gomb.
A gyerek ablakoknak van felső ikon/menüsora. Ott PLAY, PAUSE és STOP, UGRÁS, LEGVÉGÉRE UGRÁS és IDŐPONTRA UGRÁS gombok vannak egy csoportban. Itt kap helyet egy csúszka, ami a hangerőt vezérli. Minden ablaknak külön hangerőszintje van. Az alaphangerő 50%.
Egy másik csoportban MARKER+, COPY, CUT, PASTE és MIX gombok vannak. A COPY és CUT gombok csak akkor aktívak az adott gyerek-ablakban, ha ki van jelölve egy hanghullám részlet, a PASTE pedig akkor, ha van vágólapra másolva valami.
A harmadikban egy "követés" kétállású gomb, valamint zoom in és zoom out, illetve egy balra és egy jobbra gomb. A negyedik csoport egy infó gomb, ami kinyit egy kicsi információs ablakot, ahol az adott fájlról vannak adatok: név, elérési útvonal, fájltípus, a zene hossza, tömörítési ráta és ha vannak a fájlban akkor egyéb infók, pl. zeneszám címe, előadó, kiadás éve, stb.
Ha egy hangfájl-ablak aktív, mert az szól, vagy az van szerkesztve, akkor annak a kerete, fejléce legyen élénkebb, mint a többié.

hangmotor:
Az app képes legyen kezelni WAV, MP3, AAC, FLAC és OGG típusú fájlokat is. Betölteni, lejátszani, kimenteni és szerkeszteni kell tudni ezeket.
Egy sarokpont az új fájl létrehozása. itt arról van szó, hogy lehessen új hangfájl létrehozni úgy, hogy más, már megnyitott hangfájlokból összemásolja őket a felhasználó. 
Ha bezáródik egy hangfájl gyerek-ablaka, és szólt a lejátszás, akkor álljon le. Ha abból a hangfájlból van valami a vágólapon, akkor kérdezze meg, hogy megtartsa-e az app, vagy eldobható.
Minden gyerek-ablak a saját hangfájlját játsza, és ha aktívvá teszi a felhasználó az ablakot, és lejátszást nyom, akkor ahonnan folytatódjon a lejátszás, ahonnan előzőleg abbahagyta.
Minden gyerek-ablak jobb felső sarkában van egy stopper, ami mutatja, hogy a lejátszás hol tart a hangfájlban, HH:MM:SS.mmmm formában, ahol H - óra, M - perc, S - másodperc, mmmm - ezredmásodprec (4 digit)
Hangfájl mentésekor MP3-nál a bitráta, WAV-nál a mintavételi frekvencia legyen beállítható.

hanghullám:
amikor egy gyerek-ablakba betöltődik egy hangfájl, akkor az ablak méretében legyenek láthatóak a hanghullámok. Ezt lehessen zoomolni ki és be. Illetve a hanghullám képet a fogd-és-vidd technikával balra-jobbra csúsztatható legyen az ablakon belül az időskálának megfelelően.
Balra-jobbra gombok a hanghullámot mozgatják a megfelelő irányba a bezoomolt hangfájlrészlet hosszának negyedével.
Az ablak alján lehessen látni egy időskálát, a zoomolásnak megfelelő sűrűségben. Ergó ha ki van zoomlova, akkor még a másodperc is sok lehet, de ha rá van közelítve akkor az millisec is kirajzolható.
Lejátszáskor egy élénk színű függőleges vonal mutatja, hol jár a lejátszás.
A követés gomb funkciója: ha be van nyomva, akkor a lejátszás kurzor ha elhagyja az ablak jobb szélét, akkor lapoz egyet, és így a kurzor bent marad az ablakban. A lapozás mindig az az időszelet, ami a zoom szerinti ablakméret időben számítva megenged. Ha a gomb nem aktív, akkor lejátszáskor a kurzor kiléphet az ablakból. Ez a funkció összhangban és szinkronban van a Lejátszás - Lejátszás követése menüponttal.

hangkezelés:
A hanghullámra kattintva a lejátszás és a kurzor (függőleges vonal) oda ugrik, ahová kattintva lett. Ha lejátszás közben történt, akkor ugrik a lejátszás, ha nem szólt a hangfájl, akkor csak a kurzor mozog, de a play/pause hatására onnan kezdi el lejátszani a hangfájlt a motor, ahol a kurzor áll.
Az jelölőpont felvitele lényegében egy feltűnő vízszintes vonalat rajzol ki a hanghullám azon pontján, ahol épp a kurzor áll. A hanghullám közepén a jelölő vonal mellett ott a neve is, kicsi betükkel. 
Szerkesztés menüben van egy "Kijelölt rész megjelölése" (cmd + R) funkció, ami azt csinálja, ha van kijelölt rész a hangfájlban, akkor tesz egy markert az elejére és a végére is.
A lista funkció egy kis ablakot nyit, ahol a már meglévő jelölőpontok vannak időrendben listázva. Lehet őkez elnevezni és kitörölni, és színt adni nekik. A listát lehessen elmenteni és visszatölteni is. Legyen egy Bezár gomb is. A kiterjesztése a fájloknak, amiket elment VBM (VoxBarber Maker) legyen. Hangfájl neve, elérése és a markerek neve és időpontjai legyen elmentve benne. Mentéskor ajánlja fel a hangfájl nevét fájlnévnek. Betöltéskor ha már vannak markerek, akkor kérezze meg, hogy "jelölőpontok újratöltése", "jelölőpontok visszatöltése" vagy "jelölőpontok összemosása" történje-e? Újratöltéskor a jelenlegiek törlődnek, az betöltöttek lesznek érvényesek. Visszatöltéskor és összemosáskor is megmaradnak azok a már meglévő markerek, amelyeknek az időpontja nincs a betöltöttek között. Különbség annyi, hogy visszatöltéskor az egyezéseknél a betöltött név felülírja a meglévőt, míg összemosáskor a meglévő név marad meg, a betöltött helyett. A jelölőpontoknak lehessen színt adni (színválasztó), ami azt jelenti, hogy attól a ponttól kezdve a hanghullámot olyan színnel kell kirajzolni, amit itt a felhasználó megadott. A szín alapesetben (RGB ≈ 64, 166, 255), 85% átlátszatlansággal.
A gyerek-ablak "ugrás" gombja a következő marker-re ugrik a lejátszás. Ha nincs további marker, akkor visszaugrik az elsőre.
Az IDŐPONTRA UGRÁS gomb megnyomására egy pici ablak nyílik, ahol egy szövegmezőbe meg lehet adni, hová pozícionáljon a lejátszás, plusz OKÉ gomb, ami ugrik és bezárja ezt az ablakot. Az UGRÁS IDŐPONTRA gomb megyomásakor a lejátszás leáll, ha szólt a zene. A szövegmezőbe óra.perc.másodperc.ezredmásodperc formában lehet megadni az ugrás időpillanatát. Lehet pont és kettőspont is az elválasztó karakter, kivéve az utolsót, mert az csak pont lehet.

hang létrehozása:
Új hangfájl menüpont megnyit egy gyerek ablakot. Az ebben lévő hangfájlt lehet szerkeszteni. A megnyitott hangfájlokból ki lehet másolni részeket. A kijelölés a jobb egérgombbal lehetséges. Kijelölni a hanghullám egy részét lehet, a jobb egérgomb lenyomásától a felemeléséig tartó hanghullám rész legyen kijelölve, más színnel is megjelölve. Az így kialakított kijelölt hanghullám részletet lehet kimásolni vagy kivágni a gyerek-ablak megfelelő gombjaival. Amikor kirajzolódik a kijeölt rész, annak a bal felső sarkában legyen kiírva, hogy milyen hosszú időben a kijelölés HH:MM:SS.mmmm formában
A dupla jobb egér gomb kattintás kijelöli azt a hanghullám részt, ami a kijelölés pontja előtti és közvetlen utána lévő marker között van. Ha csak egy marker van, akkor attól függően, hogy a marker elé vagy mögé lett dupla-jobb kattintva a fájl elejéig vagy végéig kell kijelölni. Az így kijelölt terület ugyanolyan színűre vált, mint a hangsáv részlet jobb-gombos kijelölésénél.
Ha hangfájl részletet beilleszt valahová az app, akkor automatiksan hozzon létre két markert, a bemásolás eleje és vége legyen megjelölve.
Hangfájl részlet beillesztés után a beillesztés helye utáni markerek helye legyenek átkalkulálva, hogy ugyanoda kerüljenek, mint a beillesztés előtt.
A MIX funkció arra szolgál, hogy a kimásolt hangrészletet ha egy meglévőbe illeszti a user, akkor az nem közbeékelődik, mint a PASTE-nél, hanem a két hangfájl összemosódik. Összemosáskor a cél hangfájl mérete nem nő, hiszen a mixelésnek ez a lényege: egy adott pontban két hang hallható, az eredeti és a bemásolt/összemosott.
Ha az összemosott hangrészlet az egyesítést követően túlnyúlik az eredeti hangfájl hosszán, akkor azt meg kell növelni, még akkor is, ha oda üres részt kell tenni. Tehát, eredetileg 10sec-es hangot összemosok egy 15sec-essel, akkor az első 10sec-ben egyszerre szólnak, az utolsó 5sec-ben pedig csak az, amit ideillesztettem.
Összemosáskor egy felugró kis ablakban egyetlen csúszkán lehessen szabályozni az egymáshoz viszonyított hangerőt, ahol a csúszka eleje a célfájl, a vége pedig a beillesztendőt reprezentálja. a csúszka felett az elején és a végén legyen megjelenítve a százalékos arány, amiknek az összege minden esetben 100.