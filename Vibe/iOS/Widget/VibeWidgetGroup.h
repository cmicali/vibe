//
//  VibeWidgetGroup.h
//  Vibe (iOS)
//
//  Vibe's app group and the extension's read signal, which the app and the
//  extension each hand VibeWidgetState. COMPILED INTO BOTH TARGETS. C string
//  macros, because Swift imports them as String. Both entitlements files
//  carry the group as well.
//

#define VIBE_WIDGET_APP_GROUP           "group.com.commonwealthrecordings.Vibe"
#define VIBE_WIDGET_READ_NOTIFICATION   "com.commonwealthrecordings.Vibe.widget.read"
