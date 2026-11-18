"""Finder layout only; never modify or re-sign the supplied application."""

import os

application = os.path.abspath(defines["app"])
resources = os.path.abspath(defines["resources"])
app_name = os.path.basename(application)

format = "UDZO"
# HFS+ can synthesize FinderInfo for copied .txt resources, failing strict
# codesign checks. APFS preserves this app on its supported macOS 14+ systems.
filesystem = "APFS"
files = [
    application,
    (os.path.join(resources, "DMG-LICENSE.txt"), ".Installer-LICENSE.txt"),
]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(resources, "AppIcon.icns")
background = "builtin-arrow"

# No FinderInfo changes to the signed .app, including extension hiding.
hide_extensions = []
hide = []
default_view = "icon-view"
window_rect = ((100, 100), (640, 280))
show_toolbar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
arrange_by = None
grid_spacing = 90
icon_size = 128
text_size = 16
show_icon_preview = False
icon_locations = {app_name: (140, 120), "Applications": (500, 120)}
include_icon_view_settings = True
include_list_view_settings = False
