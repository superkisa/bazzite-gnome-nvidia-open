# Install or reinstall the Moonshine server, preserving configuration and pairings
[group('Gaming')]
moonshine-install rpm="":
    bash {{ quote(source_directory() / 'install.sh') }} {{ quote(rpm) }}

# Uninstall the Moonshine server, preserving configuration and pairings
[group('Gaming')]
moonshine-uninstall:
    bash {{ quote(source_directory() / 'uninstall.sh') }}

# Uninstall Moonshine and delete its configuration, certificates and pairings
[group('Gaming')]
moonshine-purge:
    bash {{ quote(source_directory() / 'uninstall.sh') }} --purge
