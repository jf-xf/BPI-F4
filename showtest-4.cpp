#include <iostream>
#include <string>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>
#include <sys/mman.h>
#include <opencv2/opencv.hpp>

#define DEVICE "/dev/video42"
#define WIDTH 640
#define HEIGHT 480
#define BUFFER_COUNT 4

using namespace std;
using namespace cv;

struct Buffer {
    void* start;
    size_t length;
};

void enhanceImage(Mat& img) {
    // 自动对比度 + 亮度提升
    img.convertTo(img, -1, 1.3, 10);  // alpha, beta

    // 可选：轻度锐化（增强边缘）
    Mat sharp;
    GaussianBlur(img, sharp, Size(0, 0), 3);
    addWeighted(img, 1.5, sharp, -0.5, 0, img);
}

int main() {
    int fd = open(DEVICE, O_RDWR);
    if (fd < 0) {
        perror("Failed to open device");
        return 1;
    }

    // 设置格式
    v4l2_format fmt{};
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = WIDTH;
    fmt.fmt.pix.height = HEIGHT;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_SGBRG8;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (ioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        perror("VIDIOC_S_FMT");
        return 1;
    }

    // 设置自动曝光（如果摄像头支持）
    v4l2_control ctrl{};
    ctrl.id = V4L2_CID_EXPOSURE_AUTO;
    ctrl.value = V4L2_EXPOSURE_AUTO;
    ioctl(fd, VIDIOC_S_CTRL, &ctrl);

    // 请求缓冲区
    v4l2_requestbuffers req{};
    req.count = BUFFER_COUNT;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (ioctl(fd, VIDIOC_REQBUFS, &req) < 0) {
        perror("VIDIOC_REQBUFS");
        return 1;
    }

    Buffer buffers[BUFFER_COUNT];
    for (int i = 0; i < BUFFER_COUNT; i++) {
        v4l2_buffer buf{};
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;

        if (ioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
            perror("VIDIOC_QUERYBUF");
            return 1;
        }

        buffers[i].length = buf.length;
        buffers[i].start = mmap(nullptr, buf.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, buf.m.offset);
        if (buffers[i].start == MAP_FAILED) {
            perror("mmap");
            return 1;
        }

        if (ioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF");
            return 1;
        }
    }

    v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (ioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        perror("VIDIOC_STREAMON");
        return 1;
    }

    Mat bayer(HEIGHT, WIDTH, CV_8UC1);
    Mat rgb;
    auto t0 = getTickCount();
    int frameCount = 0;

    while (true) {
        v4l2_buffer buf{};
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;

        if (ioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
            perror("VIDIOC_DQBUF");
            break;
        }

        memcpy(bayer.data, buffers[buf.index].start, buf.bytesused);
        cvtColor(bayer, rgb, COLOR_BayerGB2BGR);

        enhanceImage(rgb);

        frameCount++;
        double elapsed = (getTickCount() - t0) / getTickFrequency();
        if (elapsed >= 1.0) {
            double fps = frameCount / elapsed;
            t0 = getTickCount();
            frameCount = 0;
            string fpsText = format("FPS: %.1f", fps);
            putText(rgb, fpsText, Point(10, 30), FONT_HERSHEY_SIMPLEX, 1, Scalar(50, 255, 50), 2, LINE_AA);
        }

        rectangle(rgb, Point(0, 0), Point(rgb.cols - 1, rgb.rows - 1), Scalar(0, 255, 0), 1);
        imshow("Optimized Camera", rgb);
        if (waitKey(1) == 27) break;

        if (ioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF");
            break;
        }
    }

    ioctl(fd, VIDIOC_STREAMOFF, &type);
    close(fd);
    return 0;
}
