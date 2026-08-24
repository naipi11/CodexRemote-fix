Set-StrictMode -Version 2.0

# Tray actions no longer launch or broker an uninstall process. Keep this module
# as an inert compatibility leaf so older runtime manifests can still load it,
# but deliberately export no functions.
Export-ModuleMember -Function @()
