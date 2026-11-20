# AutoSSL — ویزارد ساده و خودکار SSL

[English](README.md) · [امنیت](SECURITY.md) · [گزارش مشکلات](ISSUES.md)

نسخه مستقل AutoSSL برای دریافت گواهی رایگان Let's Encrypt و تمدید خودکار، بر پایه [پروژه اصلی](https://github.com/monhacer/AutoSSL) با مجوز MIT.

## نصب و اجرای ویزارد

~~~bash
git clone https://github.com/MSMSofts/AutoSSL.git
cd AutoSSL
sudo bash AutoSSL.sh
~~~

یا فقط اسکریپت را دانلود و بررسی کنید:

~~~bash
curl -fSLo AutoSSL.sh https://raw.githubusercontent.com/MSMSofts/AutoSSL/main/AutoSSL.sh
sudo bash AutoSSL.sh
~~~

در منوی اصلی گزینه **۱: نصب و دریافت گواهی** را انتخاب کنید. سپس فقط دو مورد پرسیده می‌شود:

1. **دامنه**، مانند sub.example.com و بدون https.
2. **روش صدور:** گزینه ۱ برای Standalone و گزینه ۲ برای Webroot + Nginx با تنظیم خودکار.

در مسیر معمول، هیچ سؤال دیگری درباره ایمیل، نصب وابستگی‌ها، مسیر Webroot، نام سرویس یا تأیید مجدد وجود ندارد. کمبود وابستگی‌ها، نصب نسخه امضاشده acme.sh 3.1.7، صدور گواهی و تنظیم تمدید با systemd به‌صورت خودکار انجام می‌شود.

ایمیل در Let's Encrypt اجباری نیست، اما در صورت ندادن ایمیل، اعلان‌های ایمیلی را دریافت نمی‌کنید. برای ثبت ایمیل واقعی به‌صورت اختیاری:

~~~bash
sudo env AUTOSSL_EMAIL=you@example.com bash AutoSSL.sh
~~~

هیچ ایمیل جعلی ساخته نمی‌شود.

## نمایش دو مسیر PEM در پایان

پس از **صدور موفق**، در انتهای خروجی ویزارد مسیرها جداگانه نمایش داده می‌شوند:

~~~text
PRIVATE KEY (PEM) / کلید خصوصی:
 /etc/autossl/certs/sub.example.com/private.pem

PUBLIC CERTIFICATE (PEM) / گواهی عمومی:
 /etc/autossl/certs/sub.example.com/public.pem
~~~

فایل private.pem کلید محرمانه است. فایل public.pem به fullchain.pem (گواهی و زنجیره کامل) اشاره می‌کند و پس از تمدید به‌روز می‌ماند. **محتوای کلید خصوصی نمایش داده نمی‌شود.**

## انتخاب روش صدور

| روش | شرایط لازم |
| --- | --- |
| Standalone | پورت TCP 80 باید اکنون **و هنگام همه تمدیدهای آینده** آزاد و از اینترنت قابل دسترسی باشد. |
| Webroot + Nginx | پورت TCP 80 از اینترنت قابل دسترسی باشد. ابزار Nginx را در صورت نیاز نصب می‌کند؛ برای دامنه جدید مسیر و بلوک HTTP اعتبارسنجی را می‌سازد و آزمایش می‌کند. اگر Nginx از قبل برای همان دامنه server_name مشخص داشته باشد، روش موقت acme.sh --nginx جایگزین می‌شود تا تنظیمات سایت بازنویسی نشود. |

**مهم:** بلوک Nginx خودکار برای دامنه جدید فقط فایل‌های اعتبارسنجی را ارائه می‌کند و برای مسیرهای دیگر پاسخ **404** می‌دهد؛ تنظیمات HTTPS سایت یا اپلیکیشن را تغییر نمی‌دهد. اگر از virtual host پیش‌فرض یا wildcard استفاده می‌کنید، تداخل مسیریابی را پیش از استفاده عملیاتی بررسی کنید.

رکوردهای DNS (A/AAAA)، دسترسی عمومی پورت ۸۰، فایروال شرکت میزبان و NAT باید درست باشند؛ این موارد بدون دسترسی به شبکه و سرویس‌دهنده قابل اصلاح خودکار نیستند.

## دستورات مدیریتی

~~~bash
sudo autossl menu
sudo autossl status --domain sub.example.com
sudo autossl doctor --domain sub.example.com
sudo autossl renew
sudo autossl issue --domain sub.example.com --challenge standalone
sudo autossl issue --domain sub.example.com --challenge nginx
systemctl status autossl-renew.timer
journalctl -u autossl-renew.service -n 100 --no-pager
~~~

نصب غیرتعاملی، Webroot دستی و ایمیل اختیاری همچنان پشتیبانی می‌شوند. گواهی Wildcard و DNS-01 پشتیبانی نمی‌شوند. موفقیت تست‌های GitHub به معنای صدور واقعی روی VPS شما نیست؛ باید صدور و تمدید واقعی با دامنه آزمایشی نیز بررسی شود.

[مجوز اصلی](upstream/LICENSE) · [امنیت](SECURITY.md) · [گزارش فنی](ISSUES.md)
