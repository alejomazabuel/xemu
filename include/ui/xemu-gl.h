#ifndef XEMU_GL_H
#define XEMU_GL_H

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
#include <OpenGLES/ES3/gl.h>
#include <OpenGLES/ES3/glext.h>
#else
#include <epoxy/gl.h>
#endif

#endif /* XEMU_GL_H */
