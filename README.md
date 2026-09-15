# Glint

Mac menü çubuğu uygulaması. Seçtiğin uygulamalara yeni bildirim geldiğinde haber verir:

1. **Bilgisayar başındayken:** Ekranın kenarlarında o uygulamanın renginde kısa bir ışıma ve o uygulama için seçtiğin ses.
2. **Bilgisayar başında değilken:** Ekranda birkaç saniyelik bir alarm (yanıp sönen ya da sakin) ve seçtiğin ses, seçtiğin seviyede. İstersen Mac sessizdeyken de duyulur.

Tüm bildirimleri okuduğunda (rozetlerdeki sayılar 0'a indiğinde) açık kalan alarm ve ışıma kapanır.

Glint yalnızca mesajlaşma uygulamalarıyla sınırlı değildir: Dock simgesinde okunmamış sayısı (rozet) gösteren her uygulamayı ekleyebilirsin (Mail, Outlook, Takvim vb.). Microsoft Teams, WhatsApp, Telegram, Slack, Discord ve Signal yüklüyse kendiliğinden listelenir.

## Nasıl çalışır

| Parça | Yöntem |
|---|---|
| Okunmamış sayısı | Uygulamaların Dock rozeti saniyede 4 kez okunur: LaunchServices üzerinden, Erişilebilirlik izni verildiyse ayrıca doğrudan Dock'tan. Uygulamaların verisine dokunulmaz. |
| Yeni bildirim | Bir uygulamanın rozetindeki sayı arttığında. Uygulama yeni açıldıysa ilk 20 saniyedeki artışlar eski bildirimlerin yüklenmesi sayılır ve bildirilmez. |
| "Uzakta mıyım?" | Klavye/fare hareketsizlik süresi (varsayılan 2 dk) veya kilitli ekran. |

## Kurulum

1. `Glint.xcodeproj`'yi Xcode'da aç → **Glint** şeması → **Run**. İlk açılışta ayarlar penceresi kendiliğinden açılır; sonra menü çubuğundaki zil → **Ayarlar…**
2. **Genel Ayarlar** → **Erişilebilirlik** → **İzin Ver…** (önerilir; bazı uygulamaların rozeti yalnızca Dock'ta görünür). İstersen **Mac açıldığında otomatik başlat**.
3. **Uygulamalar** → izlemek istediğin uygulamaları **Uygulama Ekle** ile ekle; her birine tıklayıp rengini, sesini ve ses seviyesini seç.
4. **Alarm Ayarları** → alarm efektini ve sesini seç; **Alarmı Şimdi Test Et** ile dene.
5. **Algılama** → ne kadar hareketsiz kalınca uzakta sayılacağını seç.

## Ayarlar

Ayarlar penceresi System Settings gibidir: sayfalar solda kenar çubuğunda, sayfanın adı ve geri/ileri düğmeleri (⌘[ / ⌘]) araç çubuğunda. Pencere en son açık olan sayfayı hatırlar.

**Hakkında**
- Sürüm ve durum: izleme, izlenen uygulama sayısı, toplam okunmamış, uzakta olup olmadığın, son olay

**Uygulamalar**
- İzlenen uygulamalar; her satırda bildirim/alarm durumu, okunmamış sayısı ve ışıma rengi
- **Uygulama Ekle**: açık uygulamalardan seç ya da **Başka Bir Uygulama Seç…** ile istediğin uygulamayı ekle. Eklenen uygulamanın ışıma rengi simgesinden otomatik seçilir.
- Bir uygulamaya tıklayınca kendi sayfası açılır:
  - Glint bildirimi ve uzaktayken alarm aç/kapat, macOS'taki bildirim ayarlarına kısayol
  - Işıma rengi (varsayılana dönülebilir)
  - Bildirim sesi ve ses seviyesi (ya da Bildirim Ayarları'ndaki varsayılanlar)
  - Bildirimi ve alarmı test et; sonradan eklenen uygulamalar listeden kaldırılabilir

**Bildirim Ayarları**
- Glint bildirimlerini aç/kapat
- Varsayılan bildirim sesi ve seviyesi (kendi sesi seçilmemiş uygulamalar için)

**Alarm Ayarları**
- Uygulama bazında alarm aç/kapat ve test
- Efekt: Yanıp sönen / Sakin / Kapalı; süre 3–30 sn
- Alarm sesi ve seviyesi; **Mac sessizde olsa bile alarmı duyur** (alarm bitince ses seviyesi eski haline döner)

**Görünüm Ayarları**
- Ekran ışıması: aç/kapat, yoğunluk, süre (1–10 sn ya da bildirimler okunana kadar), önizleme
- Okunmamış sayısını menü çubuğundaki zilin yanında göster

**Algılama**
- Uzakta sayılma süresi (1–30 dk), kilitli ekranı anında uzakta say
- Şu an bilgisayar başında mı yoksa uzakta mı sayıldığın

**Genel Ayarlar**
- İzlemeyi aç/kapat, oturum açılınca başlat, Mac'in kendiliğinden uyumasını engelle
- Erişilebilirlik izni durumu

Bildirim ve alarm birbirinden bağımsızdır: bir uygulamanın bildirimini kapatmak alarmını kapatmaz.

## Menü çubuğu

Zil simgesinin yanında toplam okunmamış sayısı görünür (Görünüm Ayarları'ndan kapatılabilir). Menüde izlenen uygulamalar (okunmamış sayılarıyla, tıklayınca uygulama açılır), **İzlemeyi Duraklat/Sürdür**, **Mac'i Şimdi Kilitle**, **Ayarlar…** ve **Çık** bulunur.

## Uygulamaların kendi bildirimlerini susturmak (bir kerelik)

macOS bir uygulamanın başka bir uygulamanın bildirimlerini kapatmasına izin vermez. Ayarlar → **Uygulamalar** → uygulamanın sayfasında **Bildirim Ayarlarını Aç…** düğmesine bas → uyarı stilini **Yok** yap ve bildirim sesini kapat. **"Uygulama simgesinde işaret göster" (badge) açık kalmalı**; kapanırsa yeni bildirimler algılanamaz.

## Sınırlar

- **Mac uyanık olmalı.** Uygulama sistemin kendiliğinden uyumasını engeller ama MacBook kapağı kapanınca (harici ekran yoksa) Mac uyur ve izleme durur.
- **Kilit ekranında görüntü çıkmaz.** macOS hiçbir uygulamanın kilit ekranının üstünde görünmesine izin vermez; ekran kilitliyken sadece alarm sesi duyulur.
- **Uygulama açık olmalı.** Kapalı bir uygulamanın rozeti okunamaz.
- **Rozet gösteren uygulamalar çalışır.** Dock simgesinde sayı göstermeyen bir uygulamanın bildirimleri algılanamaz. Rozetteki sayı uygulamanın kendi ayarlarına göre değişir (ör. Teams'te sohbetler ve bahsedilmeler).
