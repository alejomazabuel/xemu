#ifndef XEMU_GL_H
#define XEMU_GL_H

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#include <OpenGLES/ES3/gl.h>
#include <OpenGLES/ES3/glext.h>
#ifndef GL_UNPACK_ROW_LENGTH_EXT
#define GL_UNPACK_ROW_LENGTH_EXT GL_UNPACK_ROW_LENGTH
#endif
#else
#include <epoxy/gl.h>
#endif

#endif /* XEMU_GL_H */
