//! Centralized closed error sets for `zvm` modules and CLI commands.
//! Explicit closed error sets catch misspelled error names and incomplete error
//! handling at compile time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const PathError = error{
    EnvironmentHomeMissing,
};

pub const PathInitError = PathError || Allocator.Error;

pub const VersionParseError = error{
    EmptyVersionString,
    InvalidVersion,
    Overflow,
    InvalidCharacter,
};

pub const ConstraintParseError = error{
    EmptyConstraint,
    InvalidMasterConstraint,
    MissingVersionAfterOperator,
    ConstraintTooLong,
    TooManyConstraintTerms,
} || VersionParseError;

pub const ResolveError = error{
    NoCompatibleVersionInstalled,
    NoVersionConfigured,
} || PathError || Allocator.Error || Io.Dir.OpenError || Io.Dir.ReadFileError || Io.Dir.AccessError;

pub const ShimError = error{
    ShimAlreadyExists,
};

pub const MinisigError = error{
    InvalidPublicKey,
    UnsupportedKeyAlgorithm,
    InvalidSignatureFormat,
    UnsupportedSignatureAlgorithm,
    KeyIdMismatch,
    SignatureVerificationFailed,
    GlobalSignatureVerificationFailed,
};

pub const TargetError = error{
    UnsupportedArchitecture,
    UnsupportedOperatingSystem,
    UnsupportedPlatformCombination,
};

pub const ArchiveError = error{
    UnsupportedArchiveFormat,
    DecompressionFailed,
    ExtractionFailed,
};

pub const ChecksumError = error{
    InvalidExpectedChecksum,
    ChecksumMismatch,
};

pub const DownloadError = error{
    HttpRequestFailed,
    InvalidIndexFormat,
    VersionNotFound,
    InvalidReleaseFormat,
    TargetNotAvailable,
    InvalidTargetFormat,
    MissingTarballUrl,
    MissingChecksum,
    InvalidArtifactFields,
} || ChecksumError || TargetError || ArchiveError || MinisigError;

pub const CliError = error{
    MissingVersion,
    InvalidVersion,
    VersionNotInstalled,
    MissingShell,
    UnsupportedShell,
};

pub const ZlsError = error{
    ZlsVersionNotFound,
    InvalidZlsResponse,
    ZlsNotInstalled,
};

/// Combined domain error set across all `zvm` subsystems.
pub const ZvmError = PathError || ConstraintParseError || ResolveError || ShimError || DownloadError || CliError || ZlsError;
