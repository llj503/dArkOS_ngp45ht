/*
 * vkmodetest: what VK_KHR_display shows a program (through the layers), and a
 * test picture on a mode of a given size.
 *
 *   vkmodetest              list the displays and modes
 *   vkmodetest W H [sec]    show the picture on a WxH mode: the listed one,
 *                           or one made with vkCreateDisplayModeKHR
 *
 * The picture: dark grey, a 8-pixel yellow frame on the image's edge, red in
 * the top left corner, green top right, blue bottom left, white bottom right.
 *
 * Build on the device (libvulkan-dev), and run it with EmulationStation
 * stopped: while ES holds the screen, the Mali driver reports no display.
 *
 *   gcc -O2 -o vkmodetest vkmodetest.c -lvulkan
 *   sudo systemctl stop emulationstation; DARKOS_VK_ROTATE_DEBUG=1 ./vkmodetest 800 600
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CK(x) do { VkResult _r = (x); if (_r != VK_SUCCESS) { printf("FAIL %s: %d\n", #x, _r); return 1; } } while (0)

int main(int argc, char **argv)
{
    uint32_t W = argc > 2 ? atoi(argv[1]) : 0, H = argc > 2 ? atoi(argv[2]) : 0;
    int secs = argc > 3 ? atoi(argv[3]) : 4;

    const char *iext[] = { VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_DISPLAY_EXTENSION_NAME,
                           VK_KHR_GET_DISPLAY_PROPERTIES_2_EXTENSION_NAME };
    uint32_t ne = 0, nx = 2;
    vkEnumerateInstanceExtensionProperties(NULL, &ne, NULL);
    VkExtensionProperties *ep = calloc(ne, sizeof(*ep));
    vkEnumerateInstanceExtensionProperties(NULL, &ne, ep);
    for (uint32_t k = 0; k < ne; k++)
        if (!strcmp(ep[k].extensionName, VK_KHR_GET_DISPLAY_PROPERTIES_2_EXTENSION_NAME))
            nx = 3;
    printf("%s: %s\n", VK_KHR_GET_DISPLAY_PROPERTIES_2_EXTENSION_NAME, nx == 3 ? "yes" : "no");
    VkApplicationInfo ai = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_0 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &ai,
        .enabledExtensionCount = nx, .ppEnabledExtensionNames = iext };
    VkInstance inst;
    CK(vkCreateInstance(&ici, NULL, &inst));
    uint32_t n = 1;
    VkPhysicalDevice pd;
    VkResult r = vkEnumeratePhysicalDevices(inst, &n, &pd);
    if (r != VK_SUCCESS && r != VK_INCOMPLETE) { printf("no gpu\n"); return 1; }

    VkDisplayPropertiesKHR dp[4];
    n = 4;
    CK(vkGetPhysicalDeviceDisplayPropertiesKHR(pd, &n, dp));
    if (!n) { printf("no display\n"); return 1; }
    VkDisplayKHR disp = dp[0].display;
    printf("display %s %ux%u\n", dp[0].displayName ? dp[0].displayName : "?",
           dp[0].physicalResolution.width, dp[0].physicalResolution.height);

    uint32_t nm = 0;
    CK(vkGetDisplayModePropertiesKHR(pd, disp, &nm, NULL));
    VkDisplayModePropertiesKHR mp[64];
    if (nm > 64) nm = 64;
    CK(vkGetDisplayModePropertiesKHR(pd, disp, &nm, mp));
    printf("%u modes:\n", nm);
    for (uint32_t k = 0; k < nm; k++)
        printf("  %ux%u @%u.%03u  %p\n", mp[k].parameters.visibleRegion.width, mp[k].parameters.visibleRegion.height,
               mp[k].parameters.refreshRate / 1000, mp[k].parameters.refreshRate % 1000, (void *)mp[k].displayMode);
    /* what a program asking for one mode only (vkcube) gets */
    VkDisplayModePropertiesKHR first;
    uint32_t one = 1;
    r = vkGetDisplayModePropertiesKHR(pd, disp, &one, &first);
    printf("first of one: %ux%u, result %d\n", first.parameters.visibleRegion.width,
           first.parameters.visibleRegion.height, r);
    VkDisplayModeProperties2KHR mp2[64];
    for (int k = 0; k < 64; k++) { mp2[k].sType = VK_STRUCTURE_TYPE_DISPLAY_MODE_PROPERTIES_2_KHR; mp2[k].pNext = NULL; }
    PFN_vkGetDisplayModeProperties2KHR gmp2 = (PFN_vkGetDisplayModeProperties2KHR)vkGetInstanceProcAddr(inst, "vkGetDisplayModeProperties2KHR");
    if (gmp2) {
        uint32_t n2 = 64;
        r = gmp2(pd, disp, &n2, mp2);
        printf("modes2: %u, result %d:", n2, r);
        for (uint32_t k = 0; k < n2; k++)
            printf(" %ux%u", mp2[k].displayModeProperties.parameters.visibleRegion.width,
                   mp2[k].displayModeProperties.parameters.visibleRegion.height);
        printf("\n");
    }
    if (!W)
        return 0;

    VkDisplayModeKHR mode = VK_NULL_HANDLE;
    for (uint32_t k = 0; k < nm; k++)
        if (mp[k].parameters.visibleRegion.width == W && mp[k].parameters.visibleRegion.height == H)
            mode = mp[k].displayMode;
    if (mode)
        printf("using listed mode %ux%u\n", W, H);
    else {
        VkDisplayModeCreateInfoKHR mci = { .sType = VK_STRUCTURE_TYPE_DISPLAY_MODE_CREATE_INFO_KHR,
            .parameters = { { W, H }, 60000 } };
        CK(vkCreateDisplayModeKHR(pd, disp, &mci, NULL, &mode));
        printf("created mode %ux%u: %p\n", W, H, (void *)mode);
    }

    VkDisplayPlaneCapabilitiesKHR pc;
    CK(vkGetDisplayPlaneCapabilitiesKHR(pd, mode, 0, &pc));
    printf("plane 0: alpha 0x%x, src %ux%u..%ux%u, dst %ux%u..%ux%u\n", pc.supportedAlpha,
           pc.minSrcExtent.width, pc.minSrcExtent.height, pc.maxSrcExtent.width, pc.maxSrcExtent.height,
           pc.minDstExtent.width, pc.minDstExtent.height, pc.maxDstExtent.width, pc.maxDstExtent.height);

    VkDisplaySurfaceCreateInfoKHR sci = { .sType = VK_STRUCTURE_TYPE_DISPLAY_SURFACE_CREATE_INFO_KHR,
        .displayMode = mode, .planeIndex = 0, .transform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        .alphaMode = VK_DISPLAY_PLANE_ALPHA_OPAQUE_BIT_KHR, .imageExtent = { W, H } };
    VkSurfaceKHR surf;
    CK(vkCreateDisplayPlaneSurfaceKHR(inst, &sci, NULL, &surf));
    VkSurfaceCapabilitiesKHR sc;
    CK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pd, surf, &sc));
    printf("surface: current %ux%u, min %ux%u, max %ux%u, images %u..%u\n",
           sc.currentExtent.width, sc.currentExtent.height, sc.minImageExtent.width, sc.minImageExtent.height,
           sc.maxImageExtent.width, sc.maxImageExtent.height, sc.minImageCount, sc.maxImageCount);
    VkSurfaceFormatKHR fm[16];
    n = 16;
    CK(vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surf, &n, fm));
    VkBool32 ok = VK_FALSE;
    CK(vkGetPhysicalDeviceSurfaceSupportKHR(pd, 0, surf, &ok));
    if (!ok) { printf("family 0 cannot present\n"); return 1; }

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0,
        .queueCount = 1, .pQueuePriorities = &prio };
    const char *dext[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci, .enabledExtensionCount = 1, .ppEnabledExtensionNames = dext };
    VkDevice dv;
    CK(vkCreateDevice(pd, &dci, NULL, &dv));
    VkQueue q;
    vkGetDeviceQueue(dv, 0, 0, &q);

    VkExtent2D ext = sc.currentExtent;
    VkSwapchainCreateInfoKHR swci = { .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, .surface = surf,
        .minImageCount = sc.minImageCount < 2 ? 2 : sc.minImageCount, .imageFormat = fm[0].format,
        .imageColorSpace = fm[0].colorSpace, .imageExtent = ext, .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT, .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR, .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR, .clipped = VK_TRUE };
    VkSwapchainKHR sw;
    CK(vkCreateSwapchainKHR(dv, &swci, NULL, &sw));
    VkImage img[8];
    uint32_t ni = 8;
    CK(vkGetSwapchainImagesKHR(dv, sw, &ni, img));
    printf("swapchain %ux%u, %u images, format %d\n", ext.width, ext.height, ni, fm[0].format);

    VkAttachmentDescription att = { .format = fm[0].format, .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR };
    VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription sub = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1, .pColorAttachments = &ref };
    VkRenderPassCreateInfo rpi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1, .pAttachments = &att, .subpassCount = 1, .pSubpasses = &sub };
    VkRenderPass rp;
    CK(vkCreateRenderPass(dv, &rpi, NULL, &rp));

    VkCommandPoolCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0 };
    VkCommandPool pool;
    CK(vkCreateCommandPool(dv, &cpi, NULL, &pool));
    VkCommandBuffer cb[8];
    VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = ni };
    CK(vkAllocateCommandBuffers(dv, &cai, cb));

    uint32_t w = ext.width, h = ext.height, qw = w / 4, qh = h / 4, f = 8;
    for (uint32_t k = 0; k < ni; k++) {
        VkImageViewCreateInfo vci = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = img[k],
            .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = fm[0].format,
            .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
        VkImageView v;
        CK(vkCreateImageView(dv, &vci, NULL, &v));
        VkFramebufferCreateInfo fbi = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = rp,
            .attachmentCount = 1, .pAttachments = &v, .width = w, .height = h, .layers = 1 };
        VkFramebuffer fb;
        CK(vkCreateFramebuffer(dv, &fbi, NULL, &fb));
        VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        CK(vkBeginCommandBuffer(cb[k], &bi));
        VkClearValue grey = { .color = { .float32 = { 0.2f, 0.2f, 0.2f, 1 } } };
        VkRenderPassBeginInfo rbi = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = rp,
            .framebuffer = fb, .renderArea = { { 0, 0 }, ext }, .clearValueCount = 1, .pClearValues = &grey };
        vkCmdBeginRenderPass(cb[k], &rbi, VK_SUBPASS_CONTENTS_INLINE);
        struct { float c[3]; VkRect2D r; } parts[] = {
            { { 1, 1, 0 }, { { 0, 0 }, { w, f } } }, { { 1, 1, 0 }, { { 0, (int32_t)(h - f) }, { w, f } } },
            { { 1, 1, 0 }, { { 0, 0 }, { f, h } } }, { { 1, 1, 0 }, { { (int32_t)(w - f), 0 }, { f, h } } },
            { { 1, 0, 0 }, { { (int32_t)f, (int32_t)f }, { qw, qh } } },
            { { 0, 1, 0 }, { { (int32_t)(w - f - qw), (int32_t)f }, { qw, qh } } },
            { { 0, 0, 1 }, { { (int32_t)f, (int32_t)(h - f - qh) }, { qw, qh } } },
            { { 1, 1, 1 }, { { (int32_t)(w - f - qw), (int32_t)(h - f - qh) }, { qw, qh } } },
        };
        for (size_t p = 0; p < sizeof(parts) / sizeof(parts[0]); p++) {
            VkClearAttachment ca = { VK_IMAGE_ASPECT_COLOR_BIT, 0,
                { .color = { .float32 = { parts[p].c[0], parts[p].c[1], parts[p].c[2], 1 } } } };
            VkClearRect cr = { parts[p].r, 0, 1 };
            vkCmdClearAttachments(cb[k], 1, &ca, 1, &cr);
        }
        vkCmdEndRenderPass(cb[k]);
        CK(vkEndCommandBuffer(cb[k]));
    }

    VkSemaphoreCreateInfo smi = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    VkSemaphore acq, done;
    CK(vkCreateSemaphore(dv, &smi, NULL, &acq));
    CK(vkCreateSemaphore(dv, &smi, NULL, &done));
    VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence;
    CK(vkCreateFence(dv, &fci, NULL, &fence));
    time_t end = time(NULL) + secs;
    int frames = 0;
    while (time(NULL) < end) {
        uint32_t idx;
        CK(vkAcquireNextImageKHR(dv, sw, UINT64_MAX, acq, VK_NULL_HANDLE, &idx));
        VkPipelineStageFlags st = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1, .pWaitSemaphores = &acq,
            .pWaitDstStageMask = &st, .commandBufferCount = 1, .pCommandBuffers = &cb[idx],
            .signalSemaphoreCount = 1, .pSignalSemaphores = &done };
        CK(vkQueueSubmit(q, 1, &si, fence));
        VkPresentInfoKHR pi = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1,
            .pWaitSemaphores = &done, .swapchainCount = 1, .pSwapchains = &sw, .pImageIndices = &idx };
        CK(vkQueuePresentKHR(q, &pi));
        CK(vkWaitForFences(dv, 1, &fence, VK_TRUE, UINT64_MAX));
        CK(vkResetFences(dv, 1, &fence));
        frames++;
    }
    printf("%d frames\n", frames);
    vkDeviceWaitIdle(dv);
    vkDestroySwapchainKHR(dv, sw, NULL);
    vkDestroySurfaceKHR(inst, surf, NULL);
    return 0;
}
