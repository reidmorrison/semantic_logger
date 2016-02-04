---
layout: default
---

### Log Rotation

Linux has exceptional support for log rotation using `logrotate`.

Example: For log rotation on a daily basis, create a file called `/etc/logrotate.d/my_app`

~~~
/var/www/rails/my_app/log/*.log {
        daily
        missingok
        copytruncate
        rotate 14
        compress
        delaycompress
        notifempty
}
~~~

Example: For long term log rotation based on log file size, or if there is a very high volume
of logging:

~~~
/var/www/rails/my_app/log/*.log {
        size 2G
        missingok
        copytruncate
        rotate 7
        compress
        nodelaycompress
        notifempty
        dateformat .%Y%m%d
}
~~~

Other log rotation tools are also available, the only requirement from a Semantic Logger perspective is that the files
must be rotated using copy-truncate to ensure that no data is lost during log rotation.

### [Next: Filtering ==>](filtering.html)
