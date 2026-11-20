# AutoSSL — نسخه مستقل با نصب ویزاردی و تمدید خودکار

[English](README.md) · [گزارش فنی مشکلات](ISSUES.md) · [امنیت](SECURITY.md)

نسخه اصلاح‌شدهٔ AutoSSL برای دریافت گواهی SSL رایگان از **Let's Encrypt** روی VPS لینوکسی. **ویزارد تعاملی نسخه اصلی حفظ شده و توسعه یافته است.** علاوه بر ویزارد، اجرای غیرتعاملی از خط فرمان نیز پشتیبانی می‌شود.

این پروژه **کاملاً مستقل از Pingtunnel** است و در مخزن جداگانه `MSMSofts/AutoSSL` نگهداری می‌شود.

## امکانات جدید

- نصب ویزاردی: انتخاب گزینه‌های نصب، ثبت دامنه، روش تأیید، نمایش گواهی، تمدید دستی، تشخیص مشکل و نصب وابستگی‌ها.
- نصب نسخهٔ امضاشده و مشخص `acme.sh 3.1.7` با بررسی SHA تگ و امضای دیجیتال؛ بدون اجرای مستقیم `curl | sh`.
- تمدید **خودکار روزانه** با `systemd timer`، اجرای جبرانی پس از خاموشی VPS و گزارش در Journal.
- روش‌های تأیید **Standalone** (بدون وب‌سرور) و **Webroot** (برای Nginx یا Apache فعال).
- اعتبارسنجی دامنه و ایمیل، کنترل شکست‌ها، قفل عملیات هم‌زمان و دسترسی محدود به کلید خصوصی.
- بدون ساخت ایمیل ساختگی، تمدید اجباری غیرضروری و Restart اتفاقی سرویس‌ها.

## پیش‌نیاز

سیستم‌عامل لینوکس با `systemd`، دسترسی `root`، دامنه‌ای که DNS آن به سرور اشاره کند و امکان اتصال پورت **TCP 80 از اینترنت**. اگر رکورد `AAAA` دارید، IPv6 هم باید درست تنظیم شده باشد.

در روش Standalone پورت ۸۰ هنگام صدور **و هنگام هر تمدید آینده** باید آزاد باشد. اگر Nginx/Apache پورت ۸۰ را گرفته است، روش Webroot را انتخاب کنید و مطمئن شوید وب‌سرور فایل‌های مسیر `/.well-known/acme-challenge/` را از webroot انتخاب‌شده ارائه می‌دهد.

## نصب ویزاردی (مانند قبل)

نصب مستقیم از مخزن مستقل GitHub:

```bash
git clone https://github.com/MSMSofts/AutoSSL.git
cd AutoSSL
sudo bash AutoSSL.sh
```

نصب سریع با دانلود تنها فایل اسکریپت:

```bash
curl -fSLo AutoSSL.sh https://raw.githubusercontent.com/MSMSofts/AutoSSL/main/AutoSSL.sh
sudo bash AutoSSL.sh
```

اسکریپت دریافتی را پیش از اجرا با دسترسی root بررسی کنید.

منوی اصلی:

```text
1) Install & obtain SSL certificate   نصب و دریافت گواهی
2) Issue another certificate          دریافت گواهی برای دامنه دیگر
3) Show certificate status            نمایش مشخصات/انقضای گواهی
4) Check automatic/manual renewal     بررسی تمدید
5) Diagnose installation             عیب‌یابی
6) Install dependencies               نصب وابستگی‌ها
0) Exit                               خروج
```

ویزارد از شما **ایمیل واقعی**، دامنه، روش صدور و در صورت نیاز مسیر Webroot و نام سرویس را می‌پرسد. پس از نصب اولیه می‌توانید فقط با `sudo autossl` به ویزارد بازگردید.

## نصب از خط فرمان

```bash
sudo bash AutoSSL.sh install --email you@example.com --install-deps
```

اگر پورت ۸۰ آزاد است:

```bash
sudo autossl issue --domain sub.example.com --challenge standalone
```

برای Nginx فعال:

```bash
sudo autossl issue --domain sub.example.com --challenge webroot --webroot /var/www/html --reload-service nginx
```

**توجه:** گزینهٔ `--reload-service nginx` فقط به سرویس تعریف‌شده فرمان Reload می‌دهد؛ سرویس باید قبلاً برای خواندن مسیرهای زیر تنظیم شده باشد. AutoSSL فایل پیکربندی Nginx را تغییر نمی‌دهد.

```text
/etc/autossl/certs/sub.example.com/private.pem
/etc/autossl/certs/sub.example.com/fullchain.pem
```

## کنترل تمدید و سلامت

```bash
sudo autossl
sudo autossl doctor --domain sub.example.com
sudo autossl status --domain sub.example.com
sudo autossl renew
systemctl list-timers --all autossl-renew.timer
journalctl -u autossl-renew.service -n 100 --no-pager
```

برای تمدید نیازی به صدور مجدد اجباری نیست؛ `acme.sh` در صورت نیاز، گواهی را تمدید می‌کند. اسکریپت خودکار برای آزادسازی پورت ۸۰ سرویس دیگری را خاموش نمی‌کند.

## نکات امنیتی

- کلید خصوصی را به هیچ عنوان در مخزن GitHub یا یک پوشه عمومی آپلود نکنید.
- تنظیم DNS و فایروال و همچنین پیکربندی واقعی وب‌سرور بر عهده مدیر سرور است.
- انتشار امضاشده acme.sh عمداً ثابت نگه داشته شده؛ آپدیت آن باید با بررسی نسخه جدید انجام شود.
- گواهی Wildcard و تأیید DNS-01 در این نسخه پشتیبانی نمی‌شوند.
- آزمون‌ها بدون اتصال به Let's Encrypt و با کلاینت شبیه‌سازی‌شده انجام می‌شوند؛ صدور/تمدید واقعی باید پیش از بهره‌برداری روی دامنه آزمایشی کنترل شود.

کد و مجوز پروژه اصلی [monhacer/AutoSSL](https://github.com/monhacer/AutoSSL) در پوشه `upstream/` نگهداری می‌شود. این مشتق با مجوز MIT ارائه می‌شود.
