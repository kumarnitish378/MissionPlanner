using System;
using System.Reflection;
using GMap.NET;
using log4net;
#if !NETSTANDARD2_0
using System.Device.Location;
#endif

namespace MissionPlanner.Utilities
{
    // Wraps the OS-reported (Windows Location Service) position of this machine,
    // for use as a placeholder map location before a vehicle is connected.
    // System.Device.Location is a .NET Framework-only API, so this is a no-op
    // on the netstandard2.0 build (used by the Android/iOS/macOS ports).
    public class DeviceLocationProvider
    {
        private static readonly ILog log = LogManager.GetLogger(MethodBase.GetCurrentMethod().DeclaringType);

        public event Action<PointLatLng> LocationChanged;

        public PointLatLng? Last { get; private set; }

#if !NETSTANDARD2_0
        private GeoCoordinateWatcher _watcher;

        public void Start()
        {
            if (_watcher != null)
                return;

            try
            {
                _watcher = new GeoCoordinateWatcher(GeoPositionAccuracy.Default);
                _watcher.PositionChanged += Watcher_PositionChanged;
                _watcher.Start();
            }
            catch (Exception ex)
            {
                // e.g. Location Service disabled/unavailable on this machine
                log.Info(ex);
            }
        }

        public void Stop()
        {
            if (_watcher == null)
                return;

            _watcher.PositionChanged -= Watcher_PositionChanged;
            try { _watcher.Stop(); } catch (Exception ex) { log.Info(ex); }
            _watcher.Dispose();
            _watcher = null;
        }

        private void Watcher_PositionChanged(object sender, GeoPositionChangedEventArgs<GeoCoordinate> e)
        {
            if (e.Position?.Location == null || e.Position.Location.IsUnknown)
                return;

            var point = new PointLatLng(e.Position.Location.Latitude, e.Position.Location.Longitude);
            Last = point;
            LocationChanged?.Invoke(point);
        }
#else
        public void Start() { }

        public void Stop() { }
#endif
    }
}
