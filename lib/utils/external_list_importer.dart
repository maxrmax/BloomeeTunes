// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
// import 'package:Bloomee/model/source_engines.dart';
import 'package:Bloomee/model/yt_music_model.dart';
import 'package:Bloomee/repository/MixedAPI/mixed_api.dart';
import 'package:Bloomee/repository/Spotify/spotify_api.dart';
import 'package:Bloomee/repository/Youtube/yt_music_api.dart';
import 'package:Bloomee/screens/widgets/snackbar.dart';
// import 'package:Bloomee/utils/country_info.dart';
import 'package:Bloomee/utils/url_checker.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:Bloomee/model/songModel.dart';
import 'package:Bloomee/model/youtube_vid_model.dart';
import 'package:Bloomee/repository/Youtube/youtube_api.dart';
import 'package:Bloomee/services/db/bloomee_db_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class ImporterState {
  int totalItems = 0;
  int importedItems = 0;
  int failedItems = 0;
  bool isDone = false;
  bool isFailed = false;
  String message = "";
  ImporterState({
    required this.totalItems,
    required this.importedItems,
    required this.failedItems,
    required this.isDone,
    required this.isFailed,
    required this.message,
  });

  ImporterState copyWith({
    int? totalItems,
    int? importedItems,
    int? failedItems,
    bool? isDone,
    bool? isFailed,
    String? message,
  }) {
    return ImporterState(
      totalItems: totalItems ?? this.totalItems,
      importedItems: importedItems ?? this.importedItems,
      failedItems: failedItems ?? this.failedItems,
      isDone: isDone ?? this.isDone,
      isFailed: isFailed ?? this.isFailed,
      message: message ?? this.message,
    );
  }
}

class ImportLogger {
  static File? _logFile;
  static IOSink? _logSink;

  static Future<void> initializeLog(String playlistName) async {
    try {
      final appDocDir = await getApplicationDocumentsDirectory();
      final logDir = Directory(p.join(appDocDir.path, 'import_logs'));
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
      final sanitizedName = playlistName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
      _logFile = File(p.join(logDir.path, 'spotify_import_${sanitizedName}_$timestamp.log'));
      _logSink = _logFile!.openWrite(mode: FileMode.write);
      
      // Write header
      _logSink!.writeln('=' * 100);
      _logSink!.writeln('Spotify Playlist Import Log');
      _logSink!.writeln('Playlist: $playlistName');
      _logSink!.writeln('Started: ${DateTime.now()}');
      _logSink!.writeln('=' * 100);
      _logSink!.writeln('');
      await _logSink!.flush();
      
      log('Import log created: ${_logFile!.path}', name: 'ImportLogger');
    } catch (e) {
      log('Failed to create log file: $e', name: 'ImportLogger');
    }
  }

  static Future<void> logImportAttempt({
    required int index,
    required String spotifyTitle,
    required String spotifyArtists,
    required String spotifyUrl,
    String? spotifyAlbum,
    String? ytmTitle,
    String? ytmArtist,
    String? ytmAlbum,
    String? ytmUrl,
    String? ytmSource,
    int? matchScore,
    bool success = false,
    String? errorMessage,
  }) async {
    if (_logSink == null) return;
    
    try {
      _logSink!.writeln('[$index] ----------------------------------------');
      _logSink!.writeln('SPOTIFY ORIGINAL:');
      _logSink!.writeln('  Title:   $spotifyTitle');
      _logSink!.writeln('  Artists: $spotifyArtists');
      if (spotifyAlbum != null) _logSink!.writeln('  Album:   $spotifyAlbum');
      _logSink!.writeln('  URL:     $spotifyUrl');
      _logSink!.writeln('');
      
      if (success && ytmTitle != null) {
        _logSink!.writeln('YOUTUBE MUSIC MATCH:');
        _logSink!.writeln('  Title:   $ytmTitle');
        _logSink!.writeln('  Artist:  $ytmArtist');
        if (ytmAlbum != null) _logSink!.writeln('  Album:   $ytmAlbum');
        _logSink!.writeln('  URL:     $ytmUrl');
        _logSink!.writeln('  Source:  $ytmSource');
        if (matchScore != null) _logSink!.writeln('  Match:   $matchScore%');
        _logSink!.writeln('  Status:  ✓ SUCCESS');
      } else {
        _logSink!.writeln('RESULT:');
        _logSink!.writeln('  Status:  ✗ FAILED');
        if (errorMessage != null) _logSink!.writeln('  Error:   $errorMessage');
      }
      _logSink!.writeln('');
      await _logSink!.flush();
    } catch (e) {
      log('Failed to write to log: $e', name: 'ImportLogger');
    }
  }

  static Future<void> finalizeLog({
    required int totalTracks,
    required int successCount,
    required int failedCount,
  }) async {
    if (_logSink == null) return;
    
    try {
      _logSink!.writeln('=' * 100);
      _logSink!.writeln('Import Complete');
      _logSink!.writeln('Finished: ${DateTime.now()}');
      _logSink!.writeln('Total Tracks: $totalTracks');
      _logSink!.writeln('Successful:   $successCount');
      _logSink!.writeln('Failed:       $failedCount');
      _logSink!.writeln('Success Rate: ${(successCount / totalTracks * 100).toStringAsFixed(2)}%');
      _logSink!.writeln('=' * 100);
      await _logSink!.flush();
      await _logSink!.close();
      
      log('Import log finalized: ${_logFile!.path}', name: 'ImportLogger');
      SnackbarService.showMessage('Import log saved to: ${_logFile!.path}', duration: const Duration(seconds: 5));
    } catch (e) {
      log('Failed to finalize log: $e', name: 'ImportLogger');
    } finally {
      _logSink = null;
      _logFile = null;
    }
  }
}

class ExternalMediaImporter {
  static Stream<ImporterState> ytPlaylistImporter(String url) async* {
    Uri uri = Uri.parse(url);
    int count = 0;
    String? playlistID;
    if (uri.host == 'youtube.com') {
      playlistID = uri.queryParameters['list'];
    }
    if (uri.host == 'youtu.be') {
      playlistID = uri.pathSegments.first;
    }
    if (playlistID != null) {
      log("Playlist ID: $playlistID", name: "Playlist Importer");
      yield ImporterState(
          totalItems: 0,
          importedItems: 0,
          failedItems: 0,
          isDone: false,
          isFailed: false,
          message: "Importing Playlist...with ID: $playlistID");
      try {
        final playlistMeta = await YoutubeExplode().playlists.get(playlistID);

        log("Playlist Name: ${playlistMeta.title}", name: "Playlist Importer");
        BloomeeDBService.createPlaylist(
          playlistMeta.title,
          source: 'youtube',
          artists: playlistMeta.author,
          description: playlistMeta.author,
          isAlbum: false,
          permaURL: playlistMeta.url,
          artURL: playlistMeta.thumbnails.mediumResUrl,
        );

        yield ImporterState(
          totalItems: playlistMeta.videoCount ?? 0,
          importedItems: 0,
          failedItems: 0,
          isDone: false,
          isFailed: false,
          message: "Importing Playlist: ${playlistMeta.title}",
        );

        final tempStrm = YoutubeExplode().playlists.getVideos(playlistID);
        await for (var video in tempStrm) {
          {
            var itemMap = await YouTubeServices()
                .formatVideo(video: video, quality: "High", getUrl: false);
            var item = fromYtVidSongMap2MediaItem(itemMap!);
            await BloomeeDBService.addMediaItem(
                MediaItem2MediaItemDB(item), playlistMeta.title);
            log("Added: ${item.title}", name: "Playlist Importer");
            yield ImporterState(
              totalItems: playlistMeta.videoCount ?? 0,
              importedItems: ++count,
              failedItems: 0,
              isDone: false,
              isFailed: false,
              message: "$count/${playlistMeta.videoCount} - ${item.title}",
            );
          }
        }
        yield ImporterState(
          totalItems: playlistMeta.videoCount ?? 0,
          importedItems: count,
          failedItems: 0,
          isDone: true,
          isFailed: false,
          message: "Imported Playlist: ${playlistMeta.title}",
        );
      } catch (e) {
        log(e.toString());
        yield ImporterState(
          totalItems: 0,
          importedItems: 0,
          failedItems: 0,
          isDone: false,
          isFailed: true,
          message: "Failed to import Playlist",
        );
      }
    }
  }

  static Stream<ImporterState> ytmPlaylistImporter(String url) async* {
    Uri uri = Uri.parse(url);
    int count = 0;
    String? playlistID;
    if (uri.host == 'music.youtube.com') {
      playlistID = uri.queryParameters['list'];
    }
    log("Playlist ID: $playlistID", name: "Playlist Importer");
    yield ImporterState(
        totalItems: 0,
        importedItems: 0,
        failedItems: 0,
        isDone: false,
        isFailed: false,
        message: "Importing Playlist...with ID: $playlistID");

    if (playlistID != null) {
      try {
        final playlistMeta = await YtMusicService().getPlaylist(playlistID);
        log("Playlist Name: ${playlistMeta['name']}",
            name: "Playlist Importer");

        BloomeeDBService.createPlaylist(
          playlistMeta['name'],
          source: 'ytmusic',
          description: playlistMeta['subtitle'],
          isAlbum: playlistMeta['type'] == "Album" ? true : false,
          permaURL: playlistMeta['url'],
          artURL: (playlistMeta['images'] as List).last,
        );
        List<MediaItemModel> mediaItems =
            fromYtSongMapList2MediaItemList(playlistMeta['songs']);
        log("Total Items: ${mediaItems.first}", name: "Playlist Importer");

        for (var item in mediaItems) {
          BloomeeDBService.addMediaItem(
              MediaItem2MediaItemDB(item), playlistMeta['name']);
          log("Added: ${item.title}", name: "Playlist Importer");
          yield ImporterState(
            totalItems: mediaItems.length,
            importedItems: ++count,
            failedItems: 0,
            isDone: false,
            isFailed: false,
            message: "$count/${mediaItems.length} - ${item.title}",
          );
        }
        yield ImporterState(
          totalItems: mediaItems.length,
          importedItems: count,
          failedItems: 0,
          isDone: true,
          isFailed: false,
          message: "Imported Playlist: ${playlistMeta['name']}",
        );
      } catch (e) {
        log(e.toString());
        yield ImporterState(
          totalItems: 0,
          importedItems: 0,
          failedItems: 0,
          isDone: false,
          isFailed: true,
          message: "Failed to import Playlist",
        );
      }
    }
  }

  static Future<MediaItemModel?> ytMediaImporter(String url) async {
    final videoId = extractVideoId(url);
    SnackbarService.showMessage("Getting Youtube Audio...", loading: true);
    if (videoId != null) {
      try {
        final video = await YoutubeExplode().videos.get(videoId);
        final itemMap = await YouTubeServices()
            .formatVideo(video: video, quality: "High", getUrl: false);
        final item = fromYtVidSongMap2MediaItem(itemMap!);
        log("Got: ${item.title}", name: "Youtube Importer");
        SnackbarService.showMessage("Got: ${item.title}");
        return item;
      } catch (e) {
        log(e.toString());
      }
    } else {
      log("Invalid Youtube URL", name: "Youtube Importer");
      SnackbarService.showMessage("Invalid Youtube URL");
    }
    return null;
  }

  static Future<MediaItemModel?> ytmMediaImporter(String url) async {
    final videoId = extractYTMusicId(url);
    SnackbarService.showMessage("Getting Youtube Music Audio...",
        loading: true);
    if (videoId != null) {
      try {
        final itemMap = await YtMusicService().getSongData(videoId: videoId);
        final item = fromYtSongMap2MediaItem(itemMap);
        log("Got: ${item.title}", name: "Youtube Music Importer");
        SnackbarService.showMessage("Got: ${item.title}");
        return item;
      } catch (e) {
        log(e.toString());
      }
    } else {
      log("Invalid Youtube Music URL", name: "Youtube Music Importer");
      SnackbarService.showMessage("Invalid Youtube Music URL");
    }
    return null;
  }

  static Stream<ImporterState> sfyPlaylistImporter(
      {required String url, String? playlistID}) async* {
    playlistID ??= extractSpotifyPlaylistId(url);
    if (playlistID != null) {
      log("Playlist ID: $playlistID", name: "Playlist Importer");
      final accessToken = await SpotifyApi().getAccessTokenCC();
      String title = '';
      try {
        yield ImporterState(
          totalItems: 0,
          importedItems: 0,
          failedItems: 0,
          isDone: false,
          isFailed: false,
          message: "Getting Spotify playlist...",
        );
        final data =
            await SpotifyApi().getAllTracksOfPlaylist(accessToken, playlistID);
        String playlistTitle = data["playlistName"].toString();
        // log(data.toString());
        final tracks = data["tracks"] as List;
        int totalItems = tracks.length;
        String artists = '';
        int i = 1;
        int failedCount = 0;
        
        if (tracks.isNotEmpty) {
          // Initialize log file
          await ImportLogger.initializeLog(playlistTitle);
          
          BloomeeDBService.createPlaylist(
            playlistTitle,
            source: 'spotify',
            description: data["description"].toString(),
            isAlbum: false,
            permaURL: data["url"].toString(),
            artURL: data["imgUrl"].toString(),
          );
          
          for (var (e as Map) in tracks) {
            try {
              title = (e['track']['name']).toString();
              artists = (e['track']['artists'] as List)
                  .map((e) => e['name'])
                  .toList()
                  .join(", ");
              final spotifyUrl = e['track']['external_urls']?['spotify']?.toString() ?? 'N/A';
              final spotifyAlbum = e['track']['album']?['name']?.toString();
              
              log("$title by $artists", name: "Playlist Importer");
              
              if (title.isNotEmpty) {
                MediaItemModel? mediaItem;
                // final country = await getCountry();
                // if (sourceEngineCountries[SourceEngine.eng_JIS]!
                //     .contains(country)) {
                //   log("Getting from MixedAPI", name: "Playlist Importer");
                //   mediaItem =
                //       await MixedAPI().getTrackMixed("$title $artists".trim());
                // } else {
                log("Getting from YTM", name: "Playlist Importer");
                mediaItem = await MixedAPI().getYtTrackByMeta(
                    "$title $artists".trim(),
                    useStringMatcher: false);
                // }
                
                if (mediaItem != null) {
                  BloomeeDBService.addMediaItem(
                      MediaItem2MediaItemDB(mediaItem), playlistTitle);
                  
                  // Log successful match
                  await ImportLogger.logImportAttempt(
                    index: i,
                    spotifyTitle: title,
                    spotifyArtists: artists,
                    spotifyUrl: spotifyUrl,
                    spotifyAlbum: spotifyAlbum,
                    ytmTitle: mediaItem.title,
                    ytmArtist: mediaItem.artist,
                    ytmAlbum: mediaItem.album,
                    ytmUrl: mediaItem.extras?['url']?.toString() ?? 'N/A',
                    ytmSource: 'ytmusic',
                    success: true,
                  );
                  
                  yield ImporterState(
                    totalItems: totalItems,
                    importedItems: i,
                    failedItems: failedCount,
                    isDone: false,
                    isFailed: false,
                    message: "Importing($i/$totalItems): ${mediaItem.title}",
                  );
                  i++;
                  log("Added: ${mediaItem.title}", name: "Playlist Importer");
                } else {
                  // Log failed match
                  failedCount++;
                  await ImportLogger.logImportAttempt(
                    index: i,
                    spotifyTitle: title,
                    spotifyArtists: artists,
                    spotifyUrl: spotifyUrl,
                    spotifyAlbum: spotifyAlbum,
                    success: false,
                    errorMessage: 'No matching YouTube Music track found',
                  );
                  log("Failed to find match for: $title by $artists", name: "Playlist Importer");
                }
              }
            } catch (e) {
              failedCount++;
              await ImportLogger.logImportAttempt(
                index: i,
                spotifyTitle: title,
                spotifyArtists: artists,
                spotifyUrl: 'Error',
                success: false,
                errorMessage: e.toString(),
              );
              log(e.toString());
              continue;
            }
          }
          
          // Finalize log
          await ImportLogger.finalizeLog(
            totalTracks: totalItems,
            successCount: i - 1,
            failedCount: failedCount,
          );
          
          yield ImporterState(
            totalItems: totalItems,
            importedItems: i - 1,
            failedItems: failedCount,
            isDone: true,
            isFailed: false,
            message: "Imported Playlist: $playlistTitle",
          );
          SnackbarService.showMessage("Imported Playlist: $playlistTitle");
        } else {
          log("Playlist is empty!!", name: "Playlist Importer");
          yield ImporterState(
            totalItems: 0,
            importedItems: 0,
            failedItems: 0,
            isDone: false,
            isFailed: true,
            message: "Playlist is empty!!",
          );
        }
      } catch (e) {
        yield ImporterState(
          totalItems: 0,
          importedItems: 0,
          failedItems: 0,
          isDone: false,
          isFailed: true,
          message: "Failed to import Playlist ${e.toString()}",
        );
        log(e.toString(), name: "Playlist Importer");
      }
    } else {
      yield ImporterState(
        totalItems: 0,
        importedItems: 0,
        failedItems: 0,
        isDone: false,
        isFailed: true,
        message: "Invalid Playlist URL",
      );
      log("Invalid Playlist URL", name: "Playlist Importer");
      SnackbarService.showMessage("Invalid Playlist URL");
    }
  }

  static Future<MediaItemModel?> sfyMediaImporter(String url) async {
    final accessToken = await SpotifyApi().getAccessTokenCC();
    SnackbarService.showMessage("Getting Spotify track using MixedAPIs...",
        duration: const Duration(seconds: 1));
    final trackId = extractSpotifyTrackId(url);
    if (trackId != null) {
      try {
        final data = await SpotifyApi().getTrackDetails(accessToken, trackId);
        final artists =
            (data['artists'] as List).map((e) => e['name']).toList().join(", ");
        final title = "${data['name']} $artists".trim().toLowerCase();

        if (title.isNotEmpty) {
          MediaItemModel? mediaItem;
          // final country = await getCountry();
          // if (sourceEngineCountries[SourceEngine.eng_JIS]!.contains(country)) {
          //   log("Getting from MixedAPI", name: "Playlist Importer");
          //   mediaItem =
          //       await MixedAPI().getTrackMixed("$title $artists".trim());
          // } else {
          log("Getting from YTM", name: "Playlist Importer");
          mediaItem =
              await MixedAPI().getYtTrackByMeta("$title $artists".trim());
          // }
          if (mediaItem != null) {
            log("Got: ${mediaItem.title}", name: "Spotify Importer");
            SnackbarService.showMessage(
                "Got Spotify track: ${mediaItem.title}");
            return mediaItem;
          } else {
            log("Not found or failed to import.", name: "Spotify Importer");
            SnackbarService.showMessage("Not found or failed to import.");
          }
        }
      } catch (e) {
        log(e.toString());
      }
    } else {
      log("Invalid Spotify URL", name: "Spotify Importer");
      SnackbarService.showMessage("Invalid Spotify URL");
    }
    return null;
  }

  static Stream<ImporterState> sfyAlbumImporter(
      {required String url, String? albumID}) async* {
    albumID ??= extractSpotifyAlbumId(url);
    if (albumID != null) {
      log("Album ID: $albumID", name: "Album Importer");
      final accessToken = await SpotifyApi().getAccessTokenCC();
      String title = '';
      try {
        yield ImporterState(
          totalItems: 0,
          importedItems: 0,
          failedItems: 0,
          isDone: false,
          isFailed: false,
          message: "Getting Spotify album...",
        );
        final data = await SpotifyApi().getAllAlbumTracks(accessToken, albumID);
        String albumTitle = data["albumName"].toString();

        BloomeeDBService.createPlaylist(
          albumTitle,
          source: 'spotify',
          description: data["description"]?.toString(),
          isAlbum: true,
          permaURL: data["url"]?.toString(),
          artURL: data["imgUrl"]?.toString(),
          artists: data["artists"]?.toString(),
        );

        final tracks = data["tracks"] as List;
        int totalItems = tracks.length;
        String artists = '';
        int i = 1;
        int failedCount = 0;
        
        if (tracks.isNotEmpty && albumTitle.isNotEmpty) {
          // Initialize log file
          await ImportLogger.initializeLog(albumTitle);
          
          for (var (e as Map) in tracks) {
            try {
              title = (e['name']).toString();
              artists = (e['artists'] as List)
                  .map((e) => e['name'])
                  .toList()
                  .join(", ");
              final spotifyUrl = e['external_urls']?['spotify']?.toString() ?? 'N/A';
              
              log("$title by $artists", name: "Album Importer");
              
              if (title.isNotEmpty) {
                MediaItemModel? mediaItem;
                // final country = await getCountry();
                // if (sourceEngineCountries[SourceEngine.eng_JIS]!
                //     .contains(country)) {
                //   log("Getting from MixedAPI", name: "Playlist Importer");
                //   mediaItem =
                //       await MixedAPI().getTrackMixed("$title $artists".trim());
                // } else {
                log("Getting from YTM", name: "Playlist Importer");
                mediaItem =
                    await MixedAPI().getYtTrackByMeta("$title $artists".trim());
                // }
                
                if (mediaItem != null) {
                  BloomeeDBService.addMediaItem(
                      MediaItem2MediaItemDB(mediaItem), albumTitle);
                  
                  // Log successful match
                  await ImportLogger.logImportAttempt(
                    index: i,
                    spotifyTitle: title,
                    spotifyArtists: artists,
                    spotifyUrl: spotifyUrl,
                    spotifyAlbum: albumTitle,
                    ytmTitle: mediaItem.title,
                    ytmArtist: mediaItem.artist,
                    ytmAlbum: mediaItem.album,
                    ytmUrl: mediaItem.extras?['url']?.toString() ?? 'N/A',
                    ytmSource: 'ytmusic',
                    success: true,
                  );
                  
                  yield ImporterState(
                    totalItems: totalItems,
                    importedItems: i,
                    failedItems: failedCount,
                    isDone: false,
                    isFailed: false,
                    message: "Importing($i/$totalItems): ${mediaItem.title}",
                  );
                  i++;
                } else {
                  // Log failed match
                  failedCount++;
                  await ImportLogger.logImportAttempt(
                    index: i,
                    spotifyTitle: title,
                    spotifyArtists: artists,
                    spotifyUrl: spotifyUrl,
                    spotifyAlbum: albumTitle,
                    success: false,
                    errorMessage: 'No matching YouTube Music track found',
                  );
                }
              }
            } catch (e) {
              failedCount++;
              await ImportLogger.logImportAttempt(
                index: i,
                spotifyTitle: title,
                spotifyArtists: artists,
                spotifyUrl: 'Error',
                success: false,
                errorMessage: e.toString(),
              );
              log(e.toString());
            }
          }
          
          // Finalize log
          await ImportLogger.finalizeLog(
            totalTracks: totalItems,
            successCount: i - 1,
            failedCount: failedCount,
          );
          
          yield ImporterState(
            totalItems: totalItems,
            importedItems: i - 1,
            failedItems: failedCount,
            isDone: true,
            isFailed: false,
            message: "Imported Album: $albumTitle",
          );
          SnackbarService.showMessage("Imported Album: $albumTitle");
        } else {
          log("Album is empty!!", name: "Album Importer");
          yield ImporterState(
            totalItems: 0,
            importedItems: 0,
            failedItems: 0,
            isDone: false,
            isFailed: true,
            message: "Album is empty!!",
          );
        }
      } catch (e) {
        yield ImporterState(
          totalItems: 0,
          importedItems: 0,
          failedItems: 0,
          isDone: false,
          isFailed: true,
          message: "Failed to import Album",
        );
        log(e.toString(), name: "Album Importer");
      }
    } else {
      yield ImporterState(
        totalItems: 0,
        importedItems: 0,
        failedItems: 0,
        isDone: false,
        isFailed: true,
        message: "Invalid Album URL",
      );
      log("Invalid Album URL", name: "Album Importer");
      SnackbarService.showMessage("Invalid Album URL");
    }
  }
}
