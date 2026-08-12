using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using WakeBar.App.Platform;
using WakeBar.Core;
using Drawing = System.Drawing;

namespace WakeBar.App.Tray;

/// <summary>
/// Draws the status icon. The Windows notification area shows a bitmap and a
/// tooltip but no text label, so the agent count that macOS prints beside the
/// menu bar symbol has to be rendered into the icon itself.
/// </summary>
public static class TrayIconRenderer
{
    /// <summary>The coordinate space the glyph geometry is authored in.</summary>
    private const double DesignSize = 64;

    private const int PixelSize = 32;

    private static readonly Typeface CountTypeface = new(
        new FontFamily("Segoe UI"),
        FontStyles.Normal,
        FontWeights.SemiBold,
        FontStretches.Normal);

    public static Drawing.Icon Render(TrayGlyph glyph, int agentCount)
    {
        var bitmap = RenderBitmap(glyph, agentCount);

        using var stream = new MemoryStream();
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        encoder.Save(stream);
        stream.Position = 0;

        using var gdiBitmap = new Drawing.Bitmap(stream);
        var iconHandle = gdiBitmap.GetHicon();
        try
        {
            using var unowned = Drawing.Icon.FromHandle(iconHandle);
            return (Drawing.Icon)unowned.Clone();
        }
        finally
        {
            NativeMethods.DestroyIcon(iconHandle);
        }
    }

    private static RenderTargetBitmap RenderBitmap(TrayGlyph glyph, int agentCount)
    {
        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen())
        {
            context.PushTransform(new ScaleTransform(PixelSize / DesignSize, PixelSize / DesignSize));

            var background = BackgroundBrush(glyph);
            context.DrawRoundedRectangle(
                background,
                null,
                new Rect(2, 2, DesignSize - 4, DesignSize - 4),
                14,
                14);

            if (agentCount > 0)
            {
                DrawCount(context, agentCount);
            }
            else
            {
                DrawGlyph(context, glyph, background);
            }

            context.Pop();
        }

        var bitmap = new RenderTargetBitmap(PixelSize, PixelSize, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return bitmap;
    }

    private static Brush BackgroundBrush(TrayGlyph glyph)
    {
        var color = glyph switch
        {
            TrayGlyph.Sleeping => Color.FromRgb(0x4B, 0x55, 0x63),
            TrayGlyph.Watching => Color.FromRgb(0x3B, 0x82, 0xF6),
            TrayGlyph.Working => Color.FromRgb(0x22, 0xC5, 0x5E),
            TrayGlyph.Locked => Color.FromRgb(0x8B, 0x5C, 0xF6),
            TrayGlyph.Grace => Color.FromRgb(0xF5, 0x9E, 0x0B),
            TrayGlyph.Degraded => Color.FromRgb(0xF5, 0x9E, 0x0B),
            _ => Color.FromRgb(0xEF, 0x44, 0x44)
        };

        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private static void DrawCount(DrawingContext context, int agentCount)
    {
        var label = agentCount > 9
            ? "9+"
            : agentCount.ToString(CultureInfo.InvariantCulture);

        var text = new FormattedText(
            label,
            CultureInfo.InvariantCulture,
            FlowDirection.LeftToRight,
            CountTypeface,
            label.Length > 1 ? 36 : 46,
            Brushes.White,
            1.0);

        context.DrawText(
            text,
            new Point((DesignSize - text.Width) / 2, (DesignSize - text.Height) / 2));
    }

    private static void DrawGlyph(DrawingContext context, TrayGlyph glyph, Brush background)
    {
        switch (glyph)
        {
            case TrayGlyph.Sleeping:
                context.DrawGeometry(Brushes.White, null, Crescent());
                break;
            case TrayGlyph.Watching:
                DrawEye(context, background);
                break;
            case TrayGlyph.Working:
            case TrayGlyph.Locked:
            case TrayGlyph.Grace:
                context.DrawGeometry(Brushes.White, null, Bolt());
                break;
            default:
                DrawExclamation(context);
                break;
        }
    }

    private static Geometry Crescent()
    {
        var outer = new EllipseGeometry(new Point(32, 32), 17, 17);
        var cutout = new EllipseGeometry(new Point(41, 23), 15, 15);
        var crescent = new CombinedGeometry(GeometryCombineMode.Exclude, outer, cutout);
        crescent.Freeze();
        return crescent;
    }

    private static Geometry Bolt()
    {
        var bolt = Geometry.Parse("M36,10 L18,36 L29,36 L26,54 L46,27 L34,27 Z");
        bolt.Freeze();
        return bolt;
    }

    private static void DrawEye(DrawingContext context, Brush background)
    {
        var outline = Geometry.Parse("M8,32 C17,18 47,18 56,32 C47,46 17,46 8,32 Z");
        outline.Freeze();
        context.DrawGeometry(Brushes.White, null, outline);
        context.DrawEllipse(background, null, new Point(32, 32), 7, 7);
    }

    private static void DrawExclamation(DrawingContext context)
    {
        context.DrawRoundedRectangle(Brushes.White, null, new Rect(28, 14, 8, 24), 4, 4);
        context.DrawEllipse(Brushes.White, null, new Point(32, 47), 5, 5);
    }
}
