# Security Policy

## Reporting a vulnerability

Please report a vulnerability privately, through GitHub's private vulnerability reporting: open the
[Security tab](https://github.com/reidmorrison/semantic_logger/security) of this repository and
choose **Report a vulnerability**. Do not open a public issue or pull request for it.

Please include the affected versions, what an attacker can do, and how to reproduce it, ideally as a
short script. Vulnerabilities in the companion gem
[rails_semantic_logger](https://github.com/reidmorrison/rails_semantic_logger) are reported the
same way in that repository.

## Supported versions

Security fixes are released for the latest minor version of the current major version.

| Version | Supported |
|---------|-----------|
| 5.x     | Yes       |
| < 5.0   | No        |

## Using Semantic Logger securely

See [Security](https://logger.reidmorrison.com/security.html) for logging untrusted data, redacting
sensitive values, transport encryption, and log file permissions.
