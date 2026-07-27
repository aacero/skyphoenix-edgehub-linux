#pragma once

#include <algorithm>
#include <cstring>

#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QQmlNetworkAccessManagerFactory>

// QML XMLHttpRequest stores its response internally, so checking responseText
// at DONE is too late to bound memory. This reply drains the real Qt reply in
// small batches, exposes at most limit + 1 bytes to the consumer, and aborts
// upstream on the first excess byte. The extra byte lets NetHub preserve its
// specific "response-too-large" result at the parser boundary.
class XeneonBoundedNetworkReply final : public QNetworkReply {
public:
    XeneonBoundedNetworkReply(QNetworkReply* upstream,
                              qint64 limit,
                              QObject* parent = nullptr)
        : QNetworkReply(parent),
          upstream_(upstream),
          limit_(std::max<qint64>(1, limit)) {
        Q_ASSERT(upstream_);
        setOperation(upstream_->operation());
        setRequest(upstream_->request());
        setUrl(upstream_->url());
        open(QIODevice::ReadOnly);
        upstream_->setReadBufferSize(limit_ + 1);
        upstream_->setParent(this);
        syncMetadata();

        connect(upstream_, &QNetworkReply::metaDataChanged, this, [this]() {
            syncMetadata();
            emit metaDataChanged();
        });
        connect(upstream_, &QIODevice::readyRead, this, [this]() {
            drain();
        });
        connect(upstream_, &QNetworkReply::downloadProgress, this,
                [this](qint64, qint64 total) {
                    emit downloadProgress(received_, total);
                });
        connect(upstream_, &QNetworkReply::errorOccurred, this,
                [this](QNetworkReply::NetworkError error) {
                    if (oversized_ || isFinished()) return;
                    setError(error, upstream_->errorString());
                    emit errorOccurred(error);
                });
        connect(upstream_, &QNetworkReply::finished, this, [this]() {
            drain();
            if (!oversized_ && upstream_->error() != QNetworkReply::NoError
                    && error() == QNetworkReply::NoError) {
                setError(upstream_->error(), upstream_->errorString());
                emit errorOccurred(upstream_->error());
            }
            finishOnce();
        });
    }

    qint64 bytesAvailable() const override {
        return buffer_.size() + QNetworkReply::bytesAvailable();
    }

    void abort() override {
        if (isFinished()) return;
        upstream_->abort();
        if (!oversized_ && error() == QNetworkReply::NoError) {
            setError(QNetworkReply::OperationCanceledError,
                     QStringLiteral("request aborted"));
            emit errorOccurred(QNetworkReply::OperationCanceledError);
        }
        finishOnce();
    }

protected:
    qint64 readData(char* data, qint64 maxSize) override {
        if (maxSize <= 0) return 0;
        if (buffer_.isEmpty()) return isFinished() ? -1 : 0;
        const qint64 count = std::min<qint64>(maxSize, buffer_.size());
        std::memcpy(data, buffer_.constData(), static_cast<std::size_t>(count));
        buffer_.remove(0, static_cast<qsizetype>(count));
        return count;
    }

private:
    void syncMetadata() {
        setUrl(upstream_->url());
        for (const auto& header : upstream_->rawHeaderPairs())
            setRawHeader(header.first, header.second);
        constexpr QNetworkRequest::Attribute attributes[] = {
            QNetworkRequest::HttpStatusCodeAttribute,
            QNetworkRequest::HttpReasonPhraseAttribute,
            QNetworkRequest::RedirectionTargetAttribute,
            QNetworkRequest::ConnectionEncryptedAttribute,
            QNetworkRequest::SourceIsFromCacheAttribute,
            QNetworkRequest::Http2WasUsedAttribute,
            QNetworkRequest::OriginalContentLengthAttribute
        };
        for (const auto attribute : attributes) {
            const QVariant value = upstream_->attribute(attribute);
            if (value.isValid()) setAttribute(attribute, value);
        }
    }

    void drain() {
        if (oversized_ || isFinished()) return;
        const QByteArray chunk = upstream_->readAll();
        if (chunk.isEmpty()) return;
        const qint64 remaining = std::max<qint64>(0, limit_ + 1 - received_);
        const qint64 accepted = std::min<qint64>(remaining, chunk.size());
        if (accepted > 0) {
            buffer_.append(chunk.constData(), static_cast<qsizetype>(accepted));
            received_ += accepted;
            emit readyRead();
        }
        if (accepted < chunk.size() || received_ > limit_)
            rejectOversized();
    }

    void rejectOversized() {
        if (oversized_ || isFinished()) return;
        oversized_ = true;
        setProperty("_xeneonResponseLimitExceeded", true);
        setError(QNetworkReply::ContentAccessDenied,
                 QStringLiteral("response exceeds configured byte limit"));
        emit errorOccurred(QNetworkReply::ContentAccessDenied);
        upstream_->abort();
        finishOnce();
    }

    void finishOnce() {
        if (isFinished()) return;
        setFinished(true);
        emit finished();
    }

    QNetworkReply* upstream_ = nullptr;
    QByteArray buffer_;
    qint64 limit_ = 0;
    qint64 received_ = 0;
    bool oversized_ = false;
};

// QML XMLHttpRequest and Image share the engine's QNetworkAccessManager. Keep
// redirects on the original origin so a URL that passed NetHub's host allowlist
// cannot silently bounce to a different host after the policy decision. Direct
// remote Image sources are separately rejected at their input boundaries.
//
// Qt 6.11.1 also has a reproducible HTTP/2 teardown defect: after a successful
// HTTPS request, QHttp2Connection can read its already-closed QSslSocket 20 to
// 30 seconds later and emit `QIODevice::read (QSslSocket): device not open`.
// These small dashboard requests do not need multiplexing. Route HTTPS over
// HTTP/1.1 until the minimum supported Qt no longer has that defect, keeping
// genuine runtime warnings actionable instead of allowlisting framework noise.
class XeneonNetworkAccessManager final : public QNetworkAccessManager {
public:
    static constexpr qint64 kMinimumResponseBytes = 1024;
    static constexpr qint64 kMaximumResponseBytes = 2 * 1024 * 1024;
    static constexpr auto kResponseLimitHeader = "X-Xeneon-Max-Response-Bytes";

    explicit XeneonNetworkAccessManager(QObject* parent = nullptr)
        : QNetworkAccessManager(parent) {}

    static qint64 responseByteLimit(const QNetworkRequest& source) {
        bool ok = false;
        const qint64 requested =
            source.rawHeader(kResponseLimitHeader).toLongLong(&ok);
        if (!ok) return kMaximumResponseBytes;
        return std::clamp(requested, kMinimumResponseBytes, kMaximumResponseBytes);
    }

    static QNetworkRequest transportRequest(const QNetworkRequest& source) {
        QNetworkRequest request(source);
        request.setRawHeader(kResponseLimitHeader, QByteArray());
        // Widget responses are small JSON, ICS, or text documents. Requesting
        // identity encoding makes downloadProgress a byte-accurate transport
        // guard instead of allowing a compressed body to expand behind it.
        request.setRawHeader("Accept-Encoding", "identity");
        request.setDecompressedSafetyCheckThreshold(kMinimumResponseBytes);
        if (request.url().scheme().compare(
                QStringLiteral("https"), Qt::CaseInsensitive) == 0)
            request.setAttribute(QNetworkRequest::Http2AllowedAttribute, false);
        return request;
    }

protected:
    QNetworkReply* createRequest(Operation operation,
                                 const QNetworkRequest& request,
                                 QIODevice* outgoingData = nullptr) override {
        const qint64 limit = responseByteLimit(request);
        QNetworkReply* reply = QNetworkAccessManager::createRequest(
            operation, transportRequest(request), outgoingData);
        if (!reply) return nullptr;
        return new XeneonBoundedNetworkReply(reply, limit, this);
    }
};

class XeneonNetworkAccessManagerFactory final : public QQmlNetworkAccessManagerFactory {
public:
    QNetworkAccessManager* create(QObject* parent) override {
        auto* manager = new XeneonNetworkAccessManager(parent);
        manager->setRedirectPolicy(QNetworkRequest::SameOriginRedirectPolicy);
        return manager;
    }
};
