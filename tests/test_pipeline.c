/* Compiles and exercises the image pipeline exactly as install.sh patches it
   into goodix52xd.c. pipeline.inc is sliced straight out of the patched tree,
   so this tests the shipped code rather than a copy of it. */
#include <glib.h>
#include <stdio.h>
#include <string.h>

#define GOODIX52XD_WIDTH 64
#define GOODIX52XD_HEIGHT 80
#define GOODIX52XD_FRAME_SIZE (GOODIX52XD_WIDTH * GOODIX52XD_HEIGHT)

typedef guint16 Goodix52xdPix;

static int dbg_quiet = 1;
#define fp_dbg(...) do { if (!dbg_quiet) { printf("  dbg: " __VA_ARGS__); printf("\n"); } } while (0)

typedef struct
{
  Goodix52xdPix *background;
  gboolean       background_used;
  guint32       *capture_sum;
  guint          capture_frames;
} FpiDeviceGoodixTls52XD;

#include "pipeline.inc"

/* The pipeline as it stood before the patch, for an equivalence check. */
static void stock_squash (const Goodix52xdPix *frame, guint8 *squashed)
{
  Goodix52xdPix min = 0xffff, max = 0;

  for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
    {
      const Goodix52xdPix pix = frame[i];
      if (pix < min)
        min = pix;
      if (pix > max)
        max = pix;
    }
  for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
    {
      const Goodix52xdPix pix = frame[i];
      if (pix - min == 0 || max - min == 0)
        squashed[i] = 0;
      else
        squashed[i] = (pix - min) * 0xff / (max - min);
    }
}

static int failures;

/* note_idle_frame repairs the dead border on the way in, so comparisons
   against a synthetic frame have to ignore that one-pixel ring. */
static int
interior_matches (const Goodix52xdPix *a, const Goodix52xdPix *b, int bias)
{
  for (int y = 1; y != GOODIX52XD_HEIGHT - 1; ++y)
    for (int x = 1; x != GOODIX52XD_WIDTH - 1; ++x)
      {
        int i = x + y * GOODIX52XD_WIDTH;
        if ((int) a[i] != (int) b[i] + bias)
          return 0;
      }
  return 1;
}

static void check (const char *what, int ok)
{
  printf ("%-58s %s\n", what, ok ? "PASS" : "FAIL");
  if (!ok)
    failures++;
}

/* A plausible idle frame: near saturation with a per-pixel fixed pattern that
   is far larger than the ridge signal we add on top of it. */
static void make_background (Goodix52xdPix *bg)
{
  for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
    {
      int x = i % GOODIX52XD_WIDTH, y = i / GOODIX52XD_WIDTH;
      /* Column gain, row offset and a speckle: ~600 counts peak to peak. */
      bg[i] = 3900 - (x * 7) % 300 - (y * 11) % 200 - ((i * 2654435761u) >> 28);
    }
}

/* Ridges every 6 px, pressing the reading down by ~120 counts: a signal one
   fifth the size of the fixed pattern, which is the whole problem. */
static void add_finger (Goodix52xdPix *frame, const Goodix52xdPix *bg, int phase)
{
  for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
    {
      int x = i % GOODIX52XD_WIDTH, y = i / GOODIX52XD_WIDTH;
      int ridge = (((x + phase) / 3 + y / 9) % 2) ? 120 : 20;
      frame[i] = bg[i] - ridge;
    }
}

int main (void)
{
  static Goodix52xdPix bg[GOODIX52XD_FRAME_SIZE];
  static Goodix52xdPix frame[GOODIX52XD_FRAME_SIZE];
  static Goodix52xdPix keep[GOODIX52XD_FRAME_SIZE];
  static guint8 patched[GOODIX52XD_FRAME_SIZE], stock[GOODIX52XD_FRAME_SIZE];

  make_background (bg);
  add_finger (frame, bg, 0);
  memcpy (keep, frame, sizeof frame);

  /* 1. No background yet: the subtraction must be a no-op, byte for byte. */
  goodix52xd_apply_background (frame, NULL);
  check ("no background leaves the frame untouched",
         memcmp (frame, keep, sizeof frame) == 0);
  squash_frame_linear (frame, patched);
  stock_squash (keep, stock);
  check ("no background gives byte-identical output to the stock pipeline",
         memcmp (patched, stock, sizeof patched) == 0);

  /* 1b. The dead border is the one thing that changes unconditionally: on a
         real 521d columns 0/63 and rows 0/79 are guard pixels reading ~600
         against a ~4000 interior, and they are identical in every capture. */
  {
    static Goodix52xdPix bordered[GOODIX52XD_FRAME_SIZE];
    int leaked = 0;

    memcpy (bordered, keep, sizeof bordered);
    for (int x = 0; x != GOODIX52XD_WIDTH; ++x)
      {
        bordered[x] = 600;
        bordered[x + (GOODIX52XD_HEIGHT - 1) * GOODIX52XD_WIDTH] = 600;
      }
    for (int y = 0; y != GOODIX52XD_HEIGHT; ++y)
      {
        bordered[y * GOODIX52XD_WIDTH] = 600;
        bordered[y * GOODIX52XD_WIDTH + GOODIX52XD_WIDTH - 1] = 600;
      }
    goodix52xd_repair_border (bordered);
    for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
      if (bordered[i] == 600 && keep[i] != 600)
        leaked++;
    check ("the dead border is replaced by live neighbours", leaked == 0);

    /* And it must not disturb anything else. */
    {
      int inner_changed = 0;
      for (int y = 1; y != GOODIX52XD_HEIGHT - 1; ++y)
        for (int x = 1; x != GOODIX52XD_WIDTH - 1; ++x)
          if (bordered[x + y * GOODIX52XD_WIDTH] != keep[x + y * GOODIX52XD_WIDTH])
            inner_changed++;
      check ("border repair leaves the interior untouched", inner_changed == 0);
    }
  }

  /* 2. With a background, ridges must come out darker than valleys. */
  memcpy (frame, keep, sizeof frame);
  goodix52xd_apply_background (frame, bg);
  squash_frame_linear (frame, patched);
  {
    long ridge_sum = 0, valley_sum = 0;
    int ridge_n = 0, valley_n = 0;

    for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
      {
        int x = i % GOODIX52XD_WIDTH, y = i / GOODIX52XD_WIDTH;
        if ((((x) / 3 + y / 9) % 2))
          ridge_sum += patched[i], ridge_n++;
        else
          valley_sum += patched[i], valley_n++;
      }
    printf ("    ridge mean %.1f, valley mean %.1f (patched)\n",
            (double) ridge_sum / ridge_n, (double) valley_sum / valley_n);
    check ("ridges come out dark and valleys light",
           (double) ridge_sum / ridge_n < 64 &&
           (double) valley_sum / valley_n > 190);
  }
  /* Same measurement through the stock pipeline, to show what it was up
     against: the fixed pattern swamps the 100-count ridge signal. */
  {
    long ridge_sum = 0, valley_sum = 0;
    int ridge_n = 0, valley_n = 0;

    stock_squash (keep, stock);
    for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
      {
        int x = i % GOODIX52XD_WIDTH, y = i / GOODIX52XD_WIDTH;
        if ((((x) / 3 + y / 9) % 2))
          ridge_sum += stock[i], ridge_n++;
        else
          valley_sum += stock[i], valley_n++;
      }
    printf ("    ridge mean %.1f, valley mean %.1f (stock, for comparison)\n",
            (double) ridge_sum / ridge_n, (double) valley_sum / valley_n);
  }

  /* 3. Two different fingers over the same background must not converge on
        the same image the way they do when the fixed pattern dominates. */
  {
    static Goodix52xdPix f2[GOODIX52XD_FRAME_SIZE];
    static guint8 a[GOODIX52XD_FRAME_SIZE], b[GOODIX52XD_FRAME_SIZE];
    long diff_patched = 0, diff_stock = 0;

    add_finger (f2, bg, 1);
    memcpy (frame, keep, sizeof frame);
    goodix52xd_apply_background (frame, bg);
    squash_frame_linear (frame, a);
    goodix52xd_apply_background (f2, bg);
    squash_frame_linear (f2, b);
    for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
      diff_patched += ABS ((int) a[i] - (int) b[i]);

    add_finger (f2, bg, 1);
    stock_squash (keep, a);
    stock_squash (f2, b);
    for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
      diff_stock += ABS ((int) a[i] - (int) b[i]);

    printf ("    mean per-pixel difference between two fingers: "
            "patched %.1f, stock %.1f\n",
            (double) diff_patched / GOODIX52XD_FRAME_SIZE,
            (double) diff_stock / GOODIX52XD_FRAME_SIZE);
    check ("two fingers separate further than under the stock pipeline",
           diff_patched > diff_stock * 2);
  }

  /* 4. Degenerate inputs must not divide by zero or wrap. */
  {
    static Goodix52xdPix flat[GOODIX52XD_FRAME_SIZE];

    for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
      flat[i] = 3900;
    memcpy (frame, flat, sizeof frame);
    goodix52xd_apply_background (frame, flat);
    squash_frame_linear (frame, patched);
    check ("a frame identical to its background survives", patched[0] == 0);

    /* Frame brighter than the background everywhere: the signal clamps at 0
       rather than wrapping around to a full-strength ridge. */
    for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
      frame[i] = flat[i] + 100;
    goodix52xd_apply_background (frame, flat);
    {
      int wrapped = 0;
      for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
        if (frame[i] != GOODIX52XD_PIX_MAX)
          wrapped++;
      check ("a frame brighter than its background does not wrap", wrapped == 0);
    }
  }

  /* 5. The clip must bound how much of the histogram it can eat. */
  {
    guint clipped = (GOODIX52XD_FRAME_SIZE * GOODIX52XD_STRETCH_CLIP_PERMILLE) / 1000;

    printf ("    clip permille %d discards %u of %d pixels per tail\n",
            GOODIX52XD_STRETCH_CLIP_PERMILLE, clipped, GOODIX52XD_FRAME_SIZE);
    check ("clip stays a small fraction of the frame",
           clipped * 4 < GOODIX52XD_FRAME_SIZE);
  }

  /* 6. A single hot pixel must not flatten the rest of the image. */
  {
    static guint8 clean[GOODIX52XD_FRAME_SIZE], hot[GOODIX52XD_FRAME_SIZE];
    long drift = 0;

    memcpy (frame, keep, sizeof frame);
    goodix52xd_apply_background (frame, bg);
    squash_frame_linear (frame, clean);

    memcpy (frame, keep, sizeof frame);
    frame[1234] = 0;                    /* dead pixel: maximal signal */
    goodix52xd_apply_background (frame, bg);
    squash_frame_linear (frame, hot);

    for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
      if (i != 1234)
        drift += ABS ((int) clean[i] - (int) hot[i]);
    printf ("    mean drift from one dead pixel: %.2f levels\n",
            (double) drift / GOODIX52XD_FRAME_SIZE);
    check ("one dead pixel barely moves the rest of the image",
           (double) drift / GOODIX52XD_FRAME_SIZE < 2.0);
  }

  /* 7. The idle-frame window: first frame seeds it, later frames of the same
        cycle can only raise it, and a capture starts a new cycle. */
  {
    FpiDeviceGoodixTls52XD dev = { NULL, FALSE };
    Goodix52xdPix *a = g_malloc (sizeof bg), *b = g_malloc (sizeof bg);
    Goodix52xdPix *c = g_malloc (sizeof bg);

    memcpy (a, bg, sizeof bg);
    goodix52xd_note_idle_frame (&dev, a);
    check ("the first idle frame seeds the background", dev.background == a);

    /* A light touch that slipped past the emptiness test: darker everywhere.
       It must not pull the background down with it. */
    for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
      b[i] = bg[i] - 90;
    goodix52xd_note_idle_frame (&dev, b);
    check ("a frame with a finger still on it cannot lower the background",
           interior_matches (dev.background, bg, 0));

    /* A genuinely brighter idle frame does raise it. */
    for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
      c[i] = bg[i] + 30;
    goodix52xd_note_idle_frame (&dev, c);
    check ("a brighter idle frame raises the background",
           interior_matches (dev.background, bg, 30));

    /* After a capture the window restarts, so drift is tracked rather than
       latched: a dimmer idle frame now replaces outright. */
    dev.background_used = TRUE;
    c = g_malloc (sizeof bg);
    for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
      c[i] = bg[i] - 200;
    goodix52xd_note_idle_frame (&dev, c);
    check ("a capture restarts the window so drift is followed",
           dev.background == c && dev.background_used == FALSE);

    g_clear_pointer (&dev.background, g_free);
    check ("background clears", dev.background == NULL);
  }

  /* 8. Multi-frame capture: one frame of this sensor is mostly noise, so the
        press is averaged. The mean must be the actual arithmetic mean, the
        accumulator must reset between presses, and an empty press must be
        reported rather than silently producing an image. */
  {
    FpiDeviceGoodixTls52XD dev = { NULL, FALSE, NULL, 0 };
    Goodix52xdPix *mean;

    check ("an empty press yields no frame", goodix52xd_take_mean_frame (&dev) == NULL);

    for (int n = 0; n != 4; ++n)
      {
        Goodix52xdPix *f = g_malloc (sizeof bg);
        for (int i = 0; i != GOODIX52XD_FRAME_SIZE; ++i)
          f[i] = (Goodix52xdPix) (1000 + n * 100);   /* mean is 1150 */
        goodix52xd_accumulate_frame (&dev, f);
      }
    check ("the press counts its frames", dev.capture_frames == 4);

    mean = goodix52xd_take_mean_frame (&dev);
    check ("the mean is the arithmetic mean", mean && mean[0] == 1150 &&
           mean[GOODIX52XD_FRAME_SIZE - 1] == 1150);
    check ("taking the mean resets the accumulator",
           dev.capture_sum == NULL && dev.capture_frames == 0);
    g_free (mean);

    /* Averaging really is averaging the signal: with a common background,
       mean(bg - f_i) == bg - mean(f_i), which is why the rest of the pipeline
       did not have to change. */
    {
      Goodix52xdPix a[4] = { 1000, 1200, 1400, 1600 };
      guint32 sum = 0;
      for (int i = 0; i != 4; ++i)
        sum += (guint32) (3000 - a[i]);
      check ("mean of the signals equals the signal of the mean",
             sum / 4 == (guint32) (3000 - (1000 + 1200 + 1400 + 1600) / 4));
    }

    /* A press abandoned half way must not bleed into the next one. */
    {
      Goodix52xdPix *f = g_malloc (sizeof bg);
      memset (f, 0, sizeof bg);
      goodix52xd_accumulate_frame (&dev, f);
      goodix52xd_drop_capture (&dev);
      check ("dropping a partial press clears it",
             dev.capture_sum == NULL && dev.capture_frames == 0);
      check ("and the next press starts empty",
             goodix52xd_take_mean_frame (&dev) == NULL);
    }
  }

  printf ("\n%s (%d failure%s)\n", failures ? "FAILED" : "all checks passed",
          failures, failures == 1 ? "" : "s");
  return failures != 0;
}
