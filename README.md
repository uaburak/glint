# Glint

Mac menü çubuğu uygulaması. Seçtiğin uygulamalara yeni bildirim geldiğinde haber verir:

1. **Bilgisayar başındayken:** Ekranın kenarlarında o uygulamanın renginde kısa bir ışıma ve o uygulama için seçtiğin ses.
2. **Bilgisayar başında değilken:** Ekranda birkaç saniyelik bir alarm (yanıp sönen ya da sakin) ve seçtiğin ses, seçtiğin seviyede. İstersen Mac sessizdeyken de duyulur, bildirim okunana kadar belirli aralıklarla tekrar eder.

Tüm bildirimleri okuduğunda (rozetlerdeki sayılar 0'a indiğinde) açık kalan alarm ve ışıma kapanır.

Glint yalnızca mesajlaşma uygulamalarıyla sınırlı değildir: Dock simgesinde okunmamış sayısı (rozet) gösteren her uygulamayı ekleyebilirsin (Mail, Outlook, Takvim vb.). Microsoft Teams, WhatsApp, Telegram, Slack, Discord ve Signal yüklüyse kendiliğinden listelenir.

## Nasıl çalışır

| Parça | Yöntem |
|---|---|
| Okunmamış sayısı | **Sistem SQLite Veritabanı:** Tam Disk Erişimi (FDA) verildiğinde doğrudan macOS'un `group.com.apple.usernoted/db2/db` veritabanı olay tabanlı (WAL izleme ile sıfır gecikmeli) okunur. **Dock / LaunchServices Fallback:** İzin verilmediğinde veya ek teyit olarak LaunchServices ve Erişilebilirlik üzerinden Dock taranır. |
| Yeni bildirim | Sistem veritabanına yeni kayıt düştüğünde; izin yoksa ya da veritabanı okunamıyorsa rozetteki sayı arttığında. Rozet artıp 5 saniye içinde kayıt gelmezse rozetten bildirilir. Uygulama yeni açıldıysa ilk 20 saniyedeki artışlar eski bildirimlerin yüklenmesi sayılır ve bildirilmez. |
| "Uzakta mıyım?" | Klavye/fare hareketsizlik süresi (varsayılan 2 dk) veya kilitli ekran. Uzaktayken çalan alarmdan sonra klavyeye ya da fareye dokunana kadar uzakta sayılırsın. |
| Sessiz mod | macOS Odak durumu (`~/Library/DoNotDisturb/DB/Assertions.json`, Tam Disk Erişimi gerekir) veya ayarlanan sessiz saatler. |

## Kurulum

1. `Glint.xcodeproj`'yi Xcode'da aç → **Glint** şeması → **Run**. İlk açılışta ayarlar penceresi kendiliğinden açılır; sonra menü çubuğundaki zil → **Ayarlar…** Aynı anda iki Glint açılırsa son açılan diğerini kapatır.
2. **Genel Ayarlar** → **İzinler**:
   - **Erişilebilirlik** → **İzin Ver…** (önerilir; Dock rozetlerini okumak için).
   - **Tam Disk Erişimi (SQLite Veritabanı)** → **Ayarları Aç…** (önerilir; mesaj içerikleri, anlık algılama ve Odak durumu için).
   - İstersen **Mac açıldığında otomatik başlat**.
3. **Uygulamalar** → izlemek istediğin uygulamaları **Uygulama Ekle** ile ekle; her birine tıklayıp rengini, sesini ve ses seviyesini seç.
4. **Alarm Ayarları** → alarm efektini, tekrarını ve sesini seç; **Alarmı Şimdi Test Et** ile dene.
5. **Algılama** → ne kadar hareketsiz kalınca uzakta sayılacağını seç.

## Ayarlar

Ayarlar penceresi System Settings gibidir: sayfalar solda kenar çubuğunda, sayfanın adı ve geri/ileri düğmeleri (⌘[ / ⌘]) araç çubuğunda. Pencere en son açık olan sayfayı hatırlar.

**Hakkında**
- Sürüm ve durum: izleme, izlenen uygulama sayısı, toplam okunmamış, izleme kaynağı, sessiz mod, uzakta olup olmadığın, son olay
- **Sağlık**: Glint'in tam çalışmasını engelleyen sorunlar ve düzeltme düğmeleri: kaldırılan izinler, okunamayan bildirim veritabanı, “Bildirim Merkezi” kapalı görünen uygulamalar. Bilerek yapılan değişiklikler **Yoksay** ile gizlenir.

**Uygulamalar**
- İzlenen uygulamalar; her satırda bildirim/alarm durumu, okunmamış sayısı ve ışıma rengi
- **Uygulama Ekle**: açık uygulamalardan seç ya da **Başka Bir Uygulama Seç…** ile istediğin uygulamayı ekle. Eklenen uygulamanın ışıma rengi simgesinden otomatik seçilir.
- Bir uygulamaya tıklayınca kendi sayfası açılır:
  - Glint bildirimi, uzaktayken alarm ve alarmı yalnızca önemli bildirimlerde çalma; macOS'taki bildirim ayarlarına kısayol
  - Işıma rengi (varsayılana dönülebilir)
  - Bildirim sesi ve ses seviyesi (ya da Bildirim Ayarları'ndaki varsayılanlar)
  - Bildirimi ve alarmı test et; sonradan eklenen uygulamalar listeden kaldırılabilir

**Bildirim Ayarları**
- Glint bildirimlerini aç/kapat; bildirim kaydı gelmezse simgedeki sayıdan bildir
- Yüzen bildirim (banner) ve konumu (köşeler, orta ya da çentik)
- Varsayılan bildirim sesi ve seviyesi (kendi sesi seçilmemiş uygulamalar için)

**Alarm Ayarları**
- Uygulama bazında alarm aç/kapat ve test
- Efekt: Yanıp sönen / Sakin / Kapalı; süre 3–30 sn
- Tekrar: bildirim okunmadıkça 1–30 dakikada bir (klavyeye ya da fareye dokununca durur)
- Alarm sesi ve seviyesi; **Mac sessizde olsa bile alarmı duyur** (alarm bitince ses seviyesi eski haline döner)

**Odak ve Öncelik**
- macOS Odak açıkken (elle ya da zamanlamayla) sessiz ol
- Her gün belirli saatlerde sessiz ol (gece yarısını geçebilir, ör. 22:00–07:00)
- Önemli kelimeler (virgülle ya da satır satır): başlığında ya da metninde geçen bildirim önemlidir; istenirse sessiz modu deler
- Sessizken ses, ışıma ve alarm olmaz; yüzen bildirimler sessizce gelir

**Görünüm Ayarları**
- Ekran ışıması: aç/kapat, yoğunluk, süre (1–10 sn ya da bildirimler okunana kadar), önizleme
- Okunmamış sayısını menü çubuğundaki zilin yanında göster

**Algılama**
- Uzakta sayılma süresi (1–30 dk), kilitli ekranı anında uzakta say
- Şu an bilgisayar başında mı yoksa uzakta mı sayıldığın

**Genel Ayarlar**
- İzlemeyi aç/kapat, oturum açılınca başlat, Mac'in kendiliğinden uyumasını engelle
- Erişilebilirlik ve Tam Disk Erişimi izin durumları
- Global kısayollar (hangi uygulama öndeyse çalışır): **Son bildirimi aç**, **Tüm bildirimleri temizle**

Bildirim ve alarm birbirinden bağımsızdır: bir uygulamanın bildirimini kapatmak alarmını kapatmaz.

## Menü çubuğu

Zil simgesinin yanında toplam okunmamış sayısı görünür (Görünüm Ayarları'ndan kapatılabilir). Simge durumu da gösterir: üzeri çizili zil duraklatıldığını, uyarı üçgeni dikkat gerektiren bir sorunu, ay sessiz modu anlatır. Menüde varsa sorunlar (tıklayınca düzeltme ayarı açılır) ve sessiz mod, izlenen uygulamalar (okunmamış sayılarıyla, tıklayınca uygulama açılır), **İzlemeyi Duraklat/Sürdür**, **Mac'i Şimdi Kilitle**, **Ayarlar…** ve **Çık** bulunur.

## Çentik

Çentikli MacBook'larda yüzen bildirimler açıkken çentik Glint'in adasına dönüşür. Bildirim gelince iki yana genişler: solda uygulamanın simgesi ve gelen bildirim sayısını gösteren rozet, sağda tüm bildirimleri temizleyen çarpı. Çentiğin üzerine gelince bekleyen bildirimler uygulamaya göre gruplanmış olarak açılır.

## Uygulamaların kendi bildirimlerini susturmak (bir kerelik)

macOS bir uygulamanın başka bir uygulamanın bildirimlerini kapatmasına izin vermez; bunu uygulamanın kendi bildirim ayarından yaparsın. Ayarlar → **Uygulamalar** → uygulamanın sayfasında **Bildirim Ayarlarını Aç…** düğmesine bas ve:

| Ayar (macOS 27) | Durum | Neden |
|---|---|---|
| Bildirimlere izin ver | Açık | Kapanırsa simge işareti ve kayıt da gelmez. |
| **Masaüstü** | **Kapalı** | macOS'un balonu çıkmaz, yüzen bildirimi Glint gösterir. |
| **Bildirim Merkezi** | **Açık** | Bildirim geçmişte kalır; Glint mesajın içeriğini buradan okur (Tam Disk Erişimi gerekir). Kapalıysa Glint Hakkında sayfasında uyarır. |
| **Uygulama simgesi işareti** | **Açık** | Glint okunmamış sayısını simgedeki sayıdan anlar; kapanırsa algılanamaz. |
| Bildirim için ses çal | Kapalı (önerilir) | Glint kendi sesini çalar. |
| Kilitli Ekran | İsteğe bağlı | Glint'i etkilemez. |

## Sınırlar

- **Mac uyanık olmalı.** Uygulama sistemin kendiliğinden uyumasını engeller ama MacBook kapağı kapanınca (harici ekran yoksa) Mac uyur ve izleme durur.
- **Kilit ekranında görüntü çıkmaz.** macOS hiçbir uygulamanın kilit ekranının üstünde görünmesine izin vermez; ekran kilitliyken sadece alarm sesi duyulur.
- **Uygulama açık olmalı (Dock modunda).** Dock/LaunchServices modunda kapalı bir uygulamanın rozeti okunamaz; ancak Tam Disk Erişimi verilip sistem SQLite veritabanı aktif olduğunda arka planda gelen sistem kayıtları yakalanabilir.
- **Rozet gösteren uygulamalar çalışır.** Dock simgesinde sayı göstermeyen bir uygulamanın bildirimleri Tam Disk Erişimi olmadan algılanamaz. Rozetteki sayı uygulamanın kendi ayarlarına göre değişir (ör. Teams'te sohbetler ve bahsedilmeler).
- **Önemli kelimeler ve Odak Tam Disk Erişimi ister.** İzin yokken bildirimin metni okunamaz; böyle bir bildirim alarm için önemli sayılır.
