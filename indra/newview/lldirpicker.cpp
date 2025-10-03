/**
 * @file lldirpicker.cpp
 * @brief OS-specific file picker
 *
 * $LicenseInfo:firstyear=2001&license=viewerlgpl$
 * Second Life Viewer Source Code
 * Copyright (C) 2010, Linden Research, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation;
 * version 2.1 of the License only.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 *
 * Linden Research, Inc., 945 Battery Street, San Francisco, CA  94111  USA
 * $/LicenseInfo$
 */

#include "llviewerprecompiledheaders.h"

#include "lldirpicker.h"
#include "llworld.h"
#include "llviewerwindow.h"
#include "llkeyboard.h"
#include "lldir.h"
#include "llframetimer.h"
#include "lltrans.h"
#include "llwindow.h"   // beforeDialog()
#include "llviewercontrol.h"
#include "llwin32headers.h"

#if LL_LINUX || LL_DARWIN
# include "llfilepicker.h"
#endif

#if LL_WINDOWS
#include <shlobj.h>
#endif

//
// Implementation
//

// utility function to check if access to local file system via file browser
// is enabled and if not, tidy up and indicate we're not allowed to do this.
bool LLDirPicker::check_local_file_access_enabled()
{
    // if local file browsing is turned off, return without opening dialog
    bool local_file_system_browsing_enabled = gSavedSettings.getBOOL("LocalFileSystemBrowsingEnabled");
    if ( ! local_file_system_browsing_enabled )
    {
        mDir.clear();   // Windows
        mFileName = NULL; // Mac/Linux
        return false;
    }

    return true;
}

#if LL_WINDOWS

LLDirPicker::LLDirPicker() :
    mFileName(NULL),
    mLocked(false),
    pDialog(NULL)
{
}

LLDirPicker::~LLDirPicker()
{
    mEventListener.disconnect();
}

void LLDirPicker::reset()
{
    if (pDialog)
    {
        IFileDialog* p_file_dialog = (IFileDialog*)pDialog;
        p_file_dialog->Close(S_FALSE);
        pDialog = NULL;
    }
}

bool LLDirPicker::getDir(std::string* filename, bool blocking)
{
    if (mLocked)
    {
        return false;
    }

    // if local file browsing is turned off, return without opening dialog
    if (!check_local_file_access_enabled())
    {
        return false;
    }

    bool success = false;

    if (blocking)
    {
        // Modal, so pause agent
        send_agent_pause();
    }
    else if (!mEventListener.connected())
    {
        mEventListener = LLEventPumps::instance().obtain("LLApp").listen(
            "DirPicker",
            [this](const LLSD& stat)
            {
                std::string status(stat["status"]);
                if (status != "running")
                {
                    reset();
                }
                return false;
            });
    }

    ::OleInitialize(NULL);

    IFileDialog* p_file_dialog;
    if (SUCCEEDED(CoCreateInstance(CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&p_file_dialog))))
    {
        DWORD dwOptions;
        if (SUCCEEDED(p_file_dialog->GetOptions(&dwOptions)))
        {
            p_file_dialog->SetOptions(dwOptions | FOS_PICKFOLDERS);
        }
        HWND owner = (HWND)gViewerWindow->getPlatformWindow();
        pDialog = p_file_dialog;
        if (SUCCEEDED(p_file_dialog->Show(owner)))
        {
            IShellItem* psi;
            if (SUCCEEDED(p_file_dialog->GetResult(&psi)))
            {
                wchar_t* pwstr = NULL;
                if (SUCCEEDED(psi->GetDisplayName(SIGDN_FILESYSPATH, &pwstr)))
                {
                    mDir = ll_convert_wide_to_string(pwstr);
                    CoTaskMemFree(pwstr);
                    success = true;
                }
                psi->Release();
            }
        }
        pDialog = NULL;
        p_file_dialog->Release();
    }

    ::OleUninitialize();

    if (blocking)
    {
        send_agent_resume();
    }

    // Account for the fact that the app has been stalled.
    LLFrameTimer::updateFrameTime();
    return success;
}

std::string LLDirPicker::getDirName()
{
    return mDir;
}

/////////////////////////////////////////////DARWIN
#elif LL_DARWIN

LLDirPicker::LLDirPicker() :
mFileName(NULL),
mLocked(false)
{
    mFilePicker = new LLFilePicker();
    reset();
}

LLDirPicker::~LLDirPicker()
{
    delete mFilePicker;
}

void LLDirPicker::reset()
{
    if (mFilePicker)
        mFilePicker->reset();
}


//static
bool LLDirPicker::getDir(std::string* filename, bool blocking)
{
    LLFilePicker::ELoadFilter filter=LLFilePicker::FFLOAD_DIRECTORY;

    return mFilePicker->getOpenFile(filter, true);
}

std::string LLDirPicker::getDirName()
{
    return mFilePicker->getFirstFile();
}

#elif LL_LINUX

# if LL_PORTAL

#include <libportal/portal.h>
#include <gio/gio.h>

LLDirPicker::LLDirPicker() :
    mFileName(NULL),
    mLocked(false)
{
    reset();
}

LLDirPicker::~LLDirPicker()
{
}

void LLDirPicker::reset()
{
    mDir.clear();
}

bool LLDirPicker::getDir(std::string* filename, bool blocking)
{
    reset();

    if (!check_local_file_access_enabled())
    {
        return false;
    }

    if (blocking)
    {
        gViewerWindow->getWindow()->beforeDialog();
        send_agent_pause();
    }

    bool success = false;

    XdpPortal* portal = xdp_portal_new();
    GMainLoop* loop = g_main_loop_new(nullptr, FALSE);
    struct Ctx { GMainLoop* loop; LLDirPicker* self; bool* ok; } ctx { loop, this, &success };

    auto cb = [](GObject* source, GAsyncResult* res, gpointer user_data){
        Ctx* c = static_cast<Ctx*>(user_data);
        g_autoptr(GError) error = nullptr;
        g_autoptr(GVariant) result = xdp_portal_open_file_finish(XDP_PORTAL(source), res, &error);
        if (result)
        {
            GVariant* uris = g_variant_lookup_value(result, "uris", G_VARIANT_TYPE("as"));
            if (uris && g_variant_n_children(uris) > 0)
            {
                GVariant* child = g_variant_get_child_value(uris, 0);
                const char* s = g_variant_get_string(child, nullptr);
                if (s)
                {
                    g_autofree char* path = g_filename_from_uri(s, nullptr, nullptr);
                    if (path)
                    {
                        if (g_file_test(path, G_FILE_TEST_IS_DIR))
                        {
                            c->self->mDir.assign(path);
                        }
                        else
                        {
                            g_autofree char* dirname = g_path_get_dirname(path);
                            if (dirname)
                            {
                                c->self->mDir.assign(dirname);
                            }
                        }
                        *(c->ok) = !c->self->mDir.empty();
                    }
                }
                g_variant_unref(child);
            }
            if (uris) g_variant_unref(uris);
        }
        g_main_loop_quit(c->loop);
    };

    const std::string title = LLTrans::getString("choose_the_directory");

    xdp_portal_open_file(portal,
                         /*parent*/ nullptr,
                         /*title*/  title.c_str(),
                         /*filters*/ nullptr,
                         /*current_filter*/ nullptr,
                         /*choices*/ nullptr,
                         /*flags*/   XDP_OPEN_FILE_FLAG_NONE,
                         /*cancellable*/ nullptr,
                         /*callback*/ cb,
                         /*data*/     &ctx);

    g_main_loop_run(loop);
    g_main_loop_unref(loop);
    g_object_unref(portal);

    if (blocking)
    {
        send_agent_resume();
        gViewerWindow->getWindow()->afterDialog();
        LLFrameTimer::updateFrameTime();
    }

    return success;
}

std::string LLDirPicker::getDirName()
{
    return mDir;
}

# else // LL_PORTAL
#  error "Linux build expects LL_PORTAL=1 for directory dialog implementation"
# endif // LL_PORTAL

#else // not implemented

LLDirPicker::LLDirPicker()
{
    reset();
}

LLDirPicker::~LLDirPicker()
{
}


void LLDirPicker::reset()
{
}

bool LLDirPicker::getDir(std::string* filename, bool blocking)
{
    return false;
}

std::string LLDirPicker::getDirName()
{
    return "";
}

#endif


LLMutex* LLDirPickerThread::sMutex = NULL;
std::queue<LLDirPickerThread*> LLDirPickerThread::sDeadQ;

void LLDirPickerThread::getFile()
{
#if LL_WINDOWS
    start();
#else
    run();
#endif
}

//virtual
void LLDirPickerThread::run()
{
#if LL_WINDOWS
    bool blocking = false;
#else
    bool blocking = true; // modal
#endif

    LLDirPicker picker;

    if (picker.getDir(&mProposedName, blocking))
    {
        mResponses.push_back(picker.getDirName());
    }

    {
        LLMutexLock lock(sMutex);
        sDeadQ.push(this);
    }

}

//static
void LLDirPickerThread::initClass()
{
    sMutex = new LLMutex();
}

//static
void LLDirPickerThread::cleanupClass()
{
    clearDead();

    delete sMutex;
    sMutex = NULL;
}

//static
void LLDirPickerThread::clearDead()
{
    if (!sDeadQ.empty())
    {
        LLMutexLock lock(sMutex);
        while (!sDeadQ.empty())
        {
            LLDirPickerThread* thread = sDeadQ.front();
            thread->notify(thread->mResponses);
            delete thread;
            sDeadQ.pop();
        }
    }
}

LLDirPickerThread::LLDirPickerThread(const dir_picked_signal_t::slot_type& cb, const std::string &proposed_name)
    : LLThread("dir picker"),
    mFilePickedSignal(NULL)
{
    mFilePickedSignal = new dir_picked_signal_t();
    mFilePickedSignal->connect(cb);
}

LLDirPickerThread::~LLDirPickerThread()
{
    delete mFilePickedSignal;
}

void LLDirPickerThread::notify(const std::vector<std::string>& filenames)
{
    if (!filenames.empty())
    {
        if (mFilePickedSignal)
        {
            (*mFilePickedSignal)(filenames, mProposedName);
        }
    }
}
