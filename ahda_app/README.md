# ahda_app (Flutter)

هذا مشروع Flutter لإدارة العُهَد والمصروفات.

## بناء APK تلقائياً عبر GitHub Actions

1) ارفع ملفات المشروع إلى GitHub (كل الملفات وليس ZIP).

2) بمجرد الرفع على فرع `main` ستعمل **GitHub Actions** تلقائياً وتبني APK (Release).

3) لتحميل الـ APK:
- ادخل تبويب **Actions**
- افتح آخر تشغيل Workflow
- انزل إلى **Artifacts**
- حمّل: `app-release-apk`

> ملاحظة: إعداد Android في هذا المشروع مُعدّ للبناء بدون `google-services.json` (تم تعطيل google-services plugin)، وبناء Release يتم بتوقيع Debug حتى لا يتطلب Keystore.
